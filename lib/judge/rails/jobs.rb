# frozen_string_literal: true

module Judge
  module Rails
    module Jobs
      extend ActiveSupport::Concern

      RETRYABLE_ERRORS = [Judge::RateLimitError, Judge::ServerError, Judge::TransportError,
                          ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout].freeze

      Payload = Struct.new(:model, :ids, :names, keyword_init: true) do
        def model_name
          model.name
        end
      end

      class << self
        def enqueuer
          @enqueuer || method(:default_enqueue)
        end

        def enqueuer=(callable)
          unless callable.respond_to?(:call)
            raise ArgumentError, "enqueuer must respond to call. Use reset_enqueuer! to restore ActiveJob"
          end

          @enqueuer = callable
        end

        def reset_enqueuer!
          @enqueuer = nil
        end

        def enqueue_record(record, names)
          enqueuer.call(Payload.new(model: record.class, ids: [record.id], names: Array(names)))
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

          Judge::Rails.log_failure(record.class, e)
          false
        rescue StandardError => e
          Judge::Rails.log_failure(record.class, e)
          false
        end

        private

        def default_enqueue(payload)
          refresh_job.perform_later(payload.model_name, payload.ids.first, payload.names.map(&:to_s))
        end

        def refresh_job
          require "judge/rails/refresh_job" if defined?(::ActiveJob)
          return Judge::Rails::RefreshJob if defined?(Judge::Rails::RefreshJob)

          raise Judge::ConfigurationError,
                "async judge attributes need ActiveJob or a custom Judge::Rails::Jobs.enqueuer. " \
                "Otherwise declare them with sync: true or callbacks: false"
        end
      end

      class_methods do
        def judge_install_callbacks(definition)
          judge_install_save_callback if definition.sync? || definition.enqueue?
          judge_install_commit_callback if definition.enqueue?
        end

        private

        def judge_install_save_callback
          return if defined?(@judge_save_callback) && @judge_save_callback

          @judge_save_callback = true
          before_save :judge_before_save
        end

        def judge_install_commit_callback
          return if defined?(@judge_commit_callback) && @judge_commit_callback

          @judge_commit_callback = true
          after_commit :judge_enqueue_refresh, on: %i[create update]
          after_rollback :judge_forget_flagged
        end
      end

      def judge_refresh_later(*names)
        names = names.flatten
        names = self.class.judge_attributes.names if names.empty?
        Jobs.enqueue_record(self, names)
      end

      private

      def judge_before_save
        automatic = self.class.judge_attributes.select { |d| d.sync? || d.enqueue? }
        pending, blank = Storage.plan(self, automatic)
        blank.each { |definition| Storage.clear(self, definition) }
        judge_flag_async(pending.keys.select(&:enqueue?))
        return if @judge_skip_inline

        Storage.groups(pending.select { |definition, _| definition.sync? }).each do |(state, model), group|
          compute_group_inline(state, model, group)
        end
      end

      def judge_flag_async(definitions)
        (@judge_flagged_async ||= Set.new).merge(definitions.map(&:name))
      end

      def judge_forget_flagged
        @judge_flagged_async = nil
      end

      def compute_group_inline(state, model, group)
        Storage.ask(self, state, model, group, adapter: @judge_refresh_adapter)
      rescue StandardError => e
        handle_inline_error(e, group)
      end

      def handle_inline_error(error, group)
        modes = group.map(&:on_error)
        raise error if modes.include?(:raise)

        Judge::Rails.log_failure(self.class, error)
        return unless modes.include?(:fail)

        names = group.select { |d| d.on_error == :fail }.map(&:name)
        errors.add(:base, "could not judge #{names.join(", ")}: #{error.class}")
        throw :abort
      end

      def judge_enqueue_refresh
        flagged = @judge_flagged_async
        judge_forget_flagged
        return if flagged.nil? || flagged.empty?

        definitions = flagged.map { |name| self.class.judge_definition(name) }
        pending = Storage.stale_definitions(self, definitions)
        Jobs.enqueue_record(self, pending.map(&:name)) if pending.any?
      end
    end
  end
end
