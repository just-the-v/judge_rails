# frozen_string_literal: true

module Jev
  module Rails
    module Jobs
      extend ActiveSupport::Concern

      Payload = Struct.new(:kind, :model, :ids, :names, keyword_init: true) do
        def model_name
          model.name
        end
      end

      BUFFER_KEY = :jev_bulk_buffer

      class << self
        attr_writer :enqueuer

        def enqueuer
          @enqueuer ||= method(:default_enqueue)
        end

        def reset_enqueuer!
          @enqueuer = nil
        end

        def enqueue_record(record, names)
          dispatch(Payload.new(kind: :record, model: record.class, ids: [record.id], names: Array(names)))
        end

        def enqueue_bulk(model, ids, names)
          names = Array(names)
          buffer = Thread.current[BUFFER_KEY]
          return dispatch(Payload.new(kind: :bulk, model: model, ids: ids, names: names)) unless buffer

          (buffer[[model, names.sort]] ||= []).concat(ids)
          nil
        end

        def batch
          previous = Thread.current[BUFFER_KEY]
          buffer = {}
          Thread.current[BUFFER_KEY] = buffer
          yield
        ensure
          Thread.current[BUFFER_KEY] = previous
          previous ? merge_into(previous, buffer) : flush(buffer)
        end

        def merge_into(target, buffer)
          buffer.each { |key, ids| (target[key] ||= []).concat(ids) }
          nil
        end

        def perform(payload, batch_size: 100, client: nil)
          model = payload.model.is_a?(String) ? payload.model.constantize : payload.model
          names = payload.names
          model.where(id: payload.ids).find_each(batch_size: batch_size) do |record|
            refresh_safely(record, names, client: client)
          end
        end

        def refresh_safely(record, names = [], client: nil)
          record.jev_refresh!(*names, client: client)
          true
        rescue StandardError => e
          log(record.class, e)
          false
        end

        def log(context, error)
          logger = Jev.config.logger
          logger&.error("[jev] refresh failed for #{context}: #{error.class}: #{error.message}")
        end

        private

        def dispatch(payload)
          enqueuer.call(payload)
        end

        def flush(buffer)
          buffer.each do |(model, names), ids|
            dispatch(Payload.new(kind: :bulk, model: model, ids: ids.uniq, names: names))
          end
        end

        def default_enqueue(payload)
          names = payload.names.map(&:to_s)
          case payload.kind
          when :record
            if defined?(Jev::Rails::RefreshJob)
              Jev::Rails::RefreshJob.perform_later(payload.model_name, payload.ids.first, names)
            end
          when :bulk
            if defined?(Jev::Rails::BulkRefreshJob)
              Jev::Rails::BulkRefreshJob.perform_later(payload.model_name, payload.ids, names)
            end
          end
        end
      end

      class_methods do
        def jev_install_callbacks(definition)
          jev_install_inline_callback if definition.sync?
          jev_install_commit_callback if definition.enqueue?
        end

        def jev_install_inline_callback
          return if defined?(@jev_inline_callback) && @jev_inline_callback

          @jev_inline_callback = true
          before_save :jev_compute_inline
        end

        def jev_install_commit_callback
          return if defined?(@jev_commit_callback) && @jev_commit_callback

          @jev_commit_callback = true
          after_commit :jev_enqueue_refresh, on: %i[create update]
        end
      end

      def jev_refresh_later(*names)
        names = names.flatten
        names = self.class.jev_attributes.names if names.empty?
        Jobs.enqueue_record(self, names)
      end

      private

      def jev_compute_inline
        definitions = self.class.jev_attributes.select(&:sync?)
        return if definitions.empty?

        pending = Storage.stale_definitions(self, definitions)
        return if pending.empty?

        Storage.group_by_state(self, pending).each do |state, group|
          compute_group_inline(state, group)
        end
      end

      def compute_group_inline(state, group)
        questions = group.to_h { |definition| [definition.name, definition.question] }
        results = Jev.ask(questions, text: state)
        group.each { |d| Storage.write(self, d, results[d.name], state: state, results: results) }
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

      def jev_enqueue_refresh
        pending = Storage.stale_definitions(self, self.class.jev_attributes.select(&:enqueue?))
        return if pending.empty?

        async, queued = pending.partition { |definition| definition.callbacks == :async }
        Jobs.enqueue_record(self, async.map(&:name)) if async.any?
        Jobs.enqueue_bulk(self.class, [id], queued.map(&:name)) if queued.any?
      end
    end

    if defined?(ActiveJob::Base)
      class RefreshJob < ActiveJob::Base
        queue_as :default

        def perform(model_name, id, names = [])
          payload = Jobs::Payload.new(kind: :record, model: model_name.constantize, ids: [id], names: names)
          Jobs.perform(payload)
        end
      end

      class BulkRefreshJob < ActiveJob::Base
        queue_as :default

        def perform(model_name, ids, names = [], batch_size: 100)
          payload = Jobs::Payload.new(kind: :bulk, model: model_name.constantize, ids: ids, names: names)
          Jobs.perform(payload, batch_size: batch_size)
        end
      end
    end
  end
end
