# frozen_string_literal: true

module Judge
  module Rails
    module Jobs
      extend ActiveSupport::Concern

      RETRYABLE_ERRORS = [Judge::RateLimitError, Judge::ServerError, Judge::TransportError].freeze

      Payload = Struct.new(:model, :ids, :names, keyword_init: true) do
        def model_name
          model.name
        end
      end

      class << self
        attr_writer :enqueuer

        def enqueuer
          @enqueuer ||= method(:default_enqueue)
        end

        def reset_enqueuer!
          @enqueuer = nil
        end

        def enqueue_record(record, names)
          dispatch(Payload.new(model: record.class, ids: [record.id], names: Array(names)))
        end

        def perform(payload, batch_size: 100, adapter: nil, raise_retryable: false)
          model = payload.model.is_a?(String) ? payload.model.constantize : payload.model
          names = payload.names
          model.where(id: payload.ids).find_each(batch_size: batch_size) do |record|
            refresh_safely(record, names, adapter: adapter, raise_retryable: raise_retryable)
          end
        end

        def refresh_safely(record, names = [], adapter: nil, raise_retryable: false)
          record.judge_refresh!(*names, adapter: adapter)
          true
        rescue *RETRYABLE_ERRORS => e
          raise if raise_retryable

          log(record.class, e)
          false
        rescue StandardError => e
          log(record.class, e)
          false
        end

        def log(context, error)
          logger = Judge.config.logger
          logger&.error("[judge] refresh failed for #{context}: #{error.class}: #{error.message}")
        end

        private

        def dispatch(payload)
          enqueuer.call(payload)
        end

        def default_enqueue(payload)
          return unless defined?(Judge::Rails::RefreshJob)

          Judge::Rails::RefreshJob.perform_later(payload.model_name, payload.ids.first,
                                                 payload.names.map(&:to_s))
        end
      end

      class_methods do
        def judge_install_callbacks(definition)
          judge_install_clear_callback if definition.sync? || definition.enqueue?
          judge_install_inline_callback if definition.sync?
          judge_install_commit_callback if definition.enqueue?
        end

        def judge_install_clear_callback
          return if defined?(@judge_clear_callback) && @judge_clear_callback

          @judge_clear_callback = true
          before_save :judge_clear_blank
        end

        def judge_install_inline_callback
          return if defined?(@judge_inline_callback) && @judge_inline_callback

          @judge_inline_callback = true
          before_save :judge_compute_inline
        end

        def judge_install_commit_callback
          return if defined?(@judge_commit_callback) && @judge_commit_callback

          @judge_commit_callback = true
          after_commit :judge_enqueue_refresh, on: %i[create update]
          after_rollback :judge_forget_refreshed
        end
      end

      def judge_refresh_later(*names)
        names = names.flatten
        names = self.class.judge_attributes.names if names.empty?
        Jobs.enqueue_record(self, names)
      end

      private

      def judge_clear_blank
        Storage.clear_blank(self, self.class.judge_attributes.select { |d| d.sync? || d.enqueue? })
        nil
      end

      def judge_compute_inline
        definitions = self.class.judge_attributes.select(&:sync?)
        return if definitions.empty?

        Storage.groups(Storage.pending(self, definitions)).each do |(state, model), group|
          compute_group_inline(state, model, group)
        end
      end

      def compute_group_inline(state, model, group)
        Storage.ask(self, state, model, group, adapter: @judge_refresh_adapter)
      rescue StandardError => e
        handle_inline_error(e, group)
      end

      def handle_inline_error(error, group)
        modes = group.map(&:on_error)
        raise error if modes.include?(:raise)

        Jobs.log(self.class, error)
        return unless modes.include?(:fail)

        names = group.select { |d| d.on_error == :fail }.map(&:name)
        errors.add(:base, "could not judge #{names.join(", ")}: #{error.class}")
        throw :abort
      end

      def judge_enqueue_refresh
        refreshed = judge_refreshed
        judge_forget_refreshed
        definitions = self.class.judge_attributes.select(&:enqueue?).reject { |d| refreshed.include?(d.name) }
        pending = Storage.stale_definitions(self, definitions)
        return if pending.empty?

        Jobs.enqueue_record(self, pending.map(&:name))
      end
    end

    if defined?(ActiveJob::Base)
      class RefreshJob < ActiveJob::Base
        queue_as :default
        retry_on(*Jobs::RETRYABLE_ERRORS, wait: :polynomially_longer, attempts: 5)

        def perform(model_name, id, names = [])
          payload = Jobs::Payload.new(model: model_name.constantize, ids: [id], names: names)
          Jobs.perform(payload, raise_retryable: true)
        end
      end
    end
  end
end
