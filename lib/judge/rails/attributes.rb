# frozen_string_literal: true

module Judge
  module Rails
    module Attributes
      extend ActiveSupport::Concern

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
        raw && Time.parse(raw)
      end

      def judge_stale?(name = nil)
        definitions = name ? [self.class.judge_definition(name)] : self.class.judge_attributes.to_a
        Storage.stale_definitions(self, definitions).any?
      end

      def judge_pending
        Storage.stale_definitions(self, self.class.judge_attributes.to_a).map(&:name)
      end

      def judge_refresh(*names, force: false, adapter: nil)
        definitions = if names.flatten.empty?
                        self.class.judge_attributes.to_a
                      else
                        names.flatten.map { |n| self.class.judge_definition(n) }
                      end
        Storage.compute(self, definitions, force: force, adapter: adapter).map(&:name)
      end

      def judge_refresh!(*names, force: false, adapter: nil)
        changed = judge_refresh(*names, force: force, adapter: adapter)
        judge_save_refreshed!(changed, adapter: adapter) if changed.any?
        changed
      end

      def judge_save_refreshed!(names, adapter: nil)
        @judge_refreshed = names.map(&:to_sym)
        @judge_refresh_adapter = adapter
        save!
      ensure
        @judge_refresh_adapter = nil
        judge_forget_refreshed unless self.class.with_connection(&:transaction_open?)
      end

      def judge_refreshed
        @judge_refreshed || []
      end

      def judge_forget_refreshed
        @judge_refreshed = nil
      end

      def judge_decide(name, above:, below: nil)
        definition = self.class.judge_definition(name)
        probability = judge_meta(name)["probability"]
        probability = read_attribute(definition.value_column) if probability.nil? && definition.type == "noul"
        raise Judge::Error, "#{name} has not been computed yet" if probability.nil?

        low = Judge.decision_band(above, below)
        return :yes if probability >= above
        return :no if probability <= low

        :unsure
      end
    end
  end
end
