# frozen_string_literal: true

module Judge
  module Rails
    module Attributes
      extend ActiveSupport::Concern

      included do
        define_model_callbacks :judge_refresh, only: :after
      end

      class_methods do
        def judge_attributes
          @judge_attributes ||=
            if superclass.respond_to?(:judge_attributes)
              superclass.judge_attributes.inherit
            else
              Registry.new
            end
        end

        def judge_source(source = nil, &block)
          @judge_default_source = block || source
        end

        def judge_default_source
          return @judge_default_source if @judge_default_source

          superclass.judge_default_source if superclass.respond_to?(:judge_default_source)
        end

        def judge_attribute(name, question, source: nil, **options)
          resolved = source || judge_default_source
          unless resolved
            raise ArgumentError,
                  "judge_attribute #{name.inspect} needs a source: or a model-level judge_source"
          end

          definition = Definition.new(name: name, question: question, source: resolved, **options)
          judge_attributes.add(definition)
          define_judge_methods(definition)
          judge_install_callbacks(definition) if respond_to?(:judge_install_callbacks)
          judge_define_scopes(definition) if respond_to?(:judge_define_scopes)
          definition
        end

        def judge_definition(name)
          judge_attributes.fetch(name)
        end

        private

        def define_judge_methods(definition)
          name = definition.name

          define_method(:"#{name}_judge_meta") { judge_meta(name) }
          define_method(:"#{name}_probability") { judge_meta(name)["probability"] }
          define_method(:"#{name}_confidence") { judge_meta(name)["confidence"] }
          define_method(:"#{name}_computed_at") { judge_computed_at(name) }
          define_method(:"#{name}_stale?") { judge_stale?(name) }

          return unless definition.type == "noul"

          define_method(:"#{name}?") do |threshold = 0.5|
            value = read_attribute(name)
            !value.nil? && value >= threshold
          end
        end
      end

      def judge_meta(name)
        Storage.sidecar(self, self.class.judge_definition(name))
      end

      def judge_computed_at(name)
        raw = judge_meta(name)["computed_at"]
        raw.is_a?(String) ? Time.parse(raw) : raw
      end

      def judge_stale?(name = nil)
        Storage.stale_definitions(self, judge_definitions_for(Array(name))).any?
      end

      def judge_pending
        Storage.stale_definitions(self, judge_definitions_for([])).map(&:name)
      end

      def judge_refresh(*names, force: false, adapter: nil, &)
        Storage.compute(self, judge_definitions_for(names), force: force, adapter: adapter, &).map(&:name)
      end

      def judge_refresh!(*names, force: false, adapter: nil, &)
        done = []
        Storage.compute(self, judge_definitions_for(names), force: force, adapter: adapter, done: done, &)
        done.map(&:name)
      ensure
        judge_persist_judgments(done, adapter: adapter) if done&.any?
      end

      def judge_decide(name, above:, below: nil)
        definition = self.class.judge_definition(name)
        probability = if definition.type == "noul"
                        read_attribute(definition.value_column)
                      else
                        judge_meta(name)["probability"]
                      end
        raise Judge::Error, "#{name} has not been computed yet" if probability.nil?

        Judge::Decision.call(probability, above: above, below: below)
      end

      private

      def judge_definitions_for(names)
        names = names.flatten
        return self.class.judge_attributes.to_a if names.empty?

        names.map { |n| self.class.judge_definition(n) }
      end

      def judge_persist_judgments(definitions, adapter: nil)
        return judge_create_with_judgments(adapter) if new_record?

        columns = definitions.flat_map { |d| [d.value_column, d.sidecar_column] }
        run_callbacks(:judge_refresh) { update_columns(columns.to_h { |c| [c, read_attribute(c)] }) }
      end

      def judge_create_with_judgments(adapter)
        @judge_refresh_adapter = adapter
        run_callbacks(:judge_refresh) { save! }
      ensure
        @judge_refresh_adapter = nil
      end
    end
  end
end
