# frozen_string_literal: true

module Jev
  module Rails
    module Refresh
      extend ActiveSupport::Concern

      Summary = Struct.new(:records, :computed, :skipped, :failed, :calls, keyword_init: true) do
        def to_h
          { records: records, computed: computed, skipped: skipped, failed: failed, calls: calls }
        end
      end

      class_methods do
        def jev_refresh_all(scope = all, batch_size: 100, force: false, resume: false, client: nil)
          definitions = jev_attributes.to_a
          summary = Summary.new(records: 0, computed: 0, skipped: 0, failed: 0, calls: 0)
          return summary if definitions.empty?

          effective_force = force && !resume
          scope.find_each(batch_size: batch_size) do |record|
            summary.records += 1
            jev_refresh_record(record, definitions, effective_force, client, summary)
          end
          summary
        end

        private

        def jev_refresh_record(record, definitions, force, client, summary)
          pending = Storage.stale_definitions(record, definitions, force: force)
          return summary.skipped += 1 if pending.empty?

          summary.calls += Storage.group_by_state(record, pending).size
          Storage.compute(record, pending, force: force, client: client)
          record.save!
          summary.computed += 1
        rescue StandardError => e
          summary.failed += 1
          Jobs.log(record.class, e)
        end
      end
    end
  end
end
