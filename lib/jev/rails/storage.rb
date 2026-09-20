# frozen_string_literal: true

module Jev
  module Rails
    module Storage
      module_function

      def stale_definitions(record, definitions, force: false)
        definitions.select do |definition|
          next false unless definition.applies_to?(record)
          next true if force

          definition.stale?(
            value: record.read_attribute(definition.value_column),
            sidecar: sidecar(record, definition),
            state: definition.state_for(record)
          )
        end
      end

      def group_by_state(record, definitions)
        definitions.group_by { |definition| definition.state_for(record) }
                   .reject { |state, _| state.to_s.strip.empty? }
      end

      def compute(record, definitions, force: false, client: nil)
        pending = stale_definitions(record, definitions, force: force)
        return [] if pending.empty?

        group_by_state(record, pending).flat_map do |state, group|
          questions = group.to_h { |d| [d.name, d.question] }
          results = Jev.ask(questions, text: state, client: client)
          group.each { |d| write(record, d, results[d.name], state: state, results: results) }
          group
        end
      end

      def write(record, definition, result, state:, results: nil)
        record.write_attribute(definition.value_column, definition.cast(result))
        record.write_attribute(
          definition.sidecar_column,
          definition.sidecar(result, state_digest: definition.state_digest(state),
                                     model: results&.model, latency: results&.latency)
        )
      end

      def clear(record, definition)
        record.write_attribute(definition.value_column, nil)
        record.write_attribute(definition.sidecar_column, {})
      end

      def sidecar(record, definition)
        value = record.read_attribute(definition.sidecar_column)
        case value
        when Hash then value
        when String then value.empty? ? {} : JSON.parse(value)
        else {}
        end
      end
    end
  end
end
