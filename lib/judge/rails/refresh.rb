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
          summary = Summary.new(records: 0, computed: 0, skipped: 0, failed: 0, calls: 0)
          effective_force = force && !resume
          scope.find_each(batch_size: batch_size) do |record|
            summary.records += 1
            judge_refresh_record(record, effective_force, adapter, summary)
          end
          summary
        end

        private

        def judge_refresh_record(record, force, adapter, summary)
          changed = record.judge_refresh!(force: force, adapter: adapter) { summary.calls += 1 }
          changed.empty? ? summary.skipped += 1 : summary.computed += 1
        rescue StandardError => e
          summary.failed += 1
          Judge::Rails.log_failure(record.class, e)
        end
      end
    end
  end
end
