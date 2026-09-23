# frozen_string_literal: true

module Judge
  module Rails
    module Storage
      module_function

      def plan(record, definitions, force: false)
        definitions.each_with_object([{}, []]) do |definition, (pending, blank)|
          next unless loaded?(record, definition) && definition.applies_to?(record)

          state = readable_state(record, definition)
          next if state.nil?

          if state.empty?
            blank << definition unless cleared?(record, definition)
          elsif force || stale?(record, definition, state)
            pending[definition] = state
          end
        end
      end

      def pending(record, definitions, force: false)
        plan(record, definitions, force: force).first
      end

      def stale_definitions(record, definitions, force: false)
        pending, blank = plan(record, definitions, force: force)
        pending.keys + blank
      end

      def groups(pending)
        pending.group_by { |definition, state| [state, definition.effective_model] }
               .transform_values { |pairs| pairs.map(&:first) }
      end

      def compute(record, definitions, force: false, adapter: nil, done: [])
        pending, blank = plan(record, definitions, force: force)
        blank.each do |definition|
          clear(record, definition)
          done << definition
        end
        groups(pending).each do |(state, model), group|
          yield if block_given?
          ask(record, state, model, group, adapter: adapter)
          done.concat(group)
        end
        done
      end

      def ask(record, state, model, group, adapter: nil)
        questions = group.to_h { |d| [d.name, d.question] }
        results = Judge.ask(questions, text: state, model: model, adapter: adapter)
        group.each { |d| write(record, d, results[d.name], state: state, results: results) }
      end

      def write(record, definition, result, state:, results: nil)
        raise Judge::InvalidResponseError, "no answer for #{definition.name.inspect}" if result.nil?

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
        when Hash then value.dup
        when String then value.empty? ? {} : JSON.parse(value)
        else {}
        end
      end

      def stale?(record, definition, state)
        definition.stale?(value: record.read_attribute(definition.value_column),
                          sidecar: sidecar(record, definition), state: state)
      end

      def cleared?(record, definition)
        record.read_attribute(definition.value_column).nil? && sidecar(record, definition).empty?
      end

      def loaded?(record, definition)
        [definition.value_column, definition.sidecar_column].all? do |column|
          record.has_attribute?(column) || !record.class.has_attribute?(column)
        end
      end

      def readable_state(record, definition)
        definition.state_for(record)
      rescue ActiveModel::MissingAttributeError
        nil
      end
    end
  end
end
