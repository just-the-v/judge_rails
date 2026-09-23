# frozen_string_literal: true

module Judge
  module Rails
    module Refresh
      extend ActiveSupport::Concern

      Summary = Struct.new(:records, :computed, :skipped, :failed, :calls, keyword_init: true) do
        def to_h
          { records: records, computed: computed, skipped: skipped, failed: failed, calls: calls }
        end
      end

      class_methods do
        def judge_refresh_all(scope = all, batch_size: 100, force: false, resume: false, adapter: nil)
          definitions = judge_attributes.to_a
          summary = Summary.new(records: 0, computed: 0, skipped: 0, failed: 0, calls: 0)
          return summary if definitions.empty?

          effective_force = force && !resume
          scope.find_each(batch_size: batch_size) do |record|
            summary.records += 1
            judge_refresh_record(record, definitions, effective_force, adapter, summary)
          end
          summary
        end

        private

        def judge_refresh_record(record, definitions, force, adapter, summary)
          pending, blank = Storage.plan(record, definitions, force: force)
          groups = Storage.groups(pending)
          return summary.skipped += 1 if groups.empty? && blank.empty?

          blank.each { |definition| Storage.clear(record, definition) }
          groups.each { |(state, model), group| Storage.ask(record, state, model, group, adapter: adapter) }
          summary.calls += groups.size
          refreshed = blank + groups.values.flatten
          record.judge_save_refreshed!(refreshed.map(&:name), adapter: adapter)
          summary.computed += 1
        rescue StandardError => e
          summary.failed += 1
          Jobs.log(record.class, e)
        end
      end
    end
  end
end
