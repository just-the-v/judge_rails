# frozen_string_literal: true

module Jev
  module Rails
    module Attributes
      extend ActiveSupport::Concern

      class_methods do
        def jev_attributes
          @jev_attributes ||=
            if superclass.respond_to?(:jev_attributes)
              superclass.jev_attributes.inherit
            else
              Registry.new
            end
        end

        def jev_source(source = nil, &block)
          @jev_default_source = block || source
        end

        def jev_default_source
          return @jev_default_source if @jev_default_source

          superclass.jev_default_source if superclass.respond_to?(:jev_default_source)
        end

        def jev_attribute(name, question, source: nil, **options)
          resolved = source || jev_default_source
          unless resolved
            raise ArgumentError,
                  "jev_attribute #{name.inspect} needs a source: or a model-level jev_source"
          end

          definition = Definition.new(name: name, question: question, source: resolved, **options)
          jev_attributes.add(definition)
          define_jev_methods(definition)
          jev_install_callbacks(definition) if respond_to?(:jev_install_callbacks)
          definition
        end

        def jev_definition(name)
          jev_attributes.fetch(name)
        end

        private

        def define_jev_methods(definition)
          name = definition.name

          define_method(:"#{name}_jev_meta") { jev_meta(name) }
          define_method(:"#{name}_probability") { jev_meta(name)["probability"] }
          define_method(:"#{name}_confidence") { jev_meta(name)["confidence"] }
          define_method(:"#{name}_computed_at") { jev_computed_at(name) }
          define_method(:"#{name}_stale?") { jev_stale?(name) }

          return unless definition.type == "noul"

          define_method(:"#{name}?") do |threshold = 0.5|
            value = read_attribute(name)
            !value.nil? && value >= threshold
          end
        end
      end

      def jev_meta(name)
        Storage.sidecar(self, self.class.jev_definition(name))
      end

      def jev_computed_at(name)
        raw = jev_meta(name)["computed_at"]
        raw && Time.parse(raw)
      end

      def jev_stale?(name = nil)
        definitions = name ? [self.class.jev_definition(name)] : self.class.jev_attributes.to_a
        Storage.stale_definitions(self, definitions).any?
      end

      def jev_pending
        Storage.stale_definitions(self, self.class.jev_attributes.to_a).map(&:name)
      end

      def jev_refresh(*names, force: false, client: nil)
        definitions = if names.flatten.empty?
                        self.class.jev_attributes.to_a
                      else
                        names.flatten.map { |n| self.class.jev_definition(n) }
                      end
        Storage.compute(self, definitions, force: force, client: client).map(&:name)
      end

      def jev_refresh!(*names, force: false, client: nil)
        changed = jev_refresh(*names, force: force, client: client)
        save! if changed.any?
        changed
      end

      def jev_decide(name, above:, below: nil)
        definition = self.class.jev_definition(name)
        probability = jev_meta(name)["probability"]
        probability = read_attribute(definition.value_column) if probability.nil? && definition.type == "noul"
        raise Jev::Error, "#{name} has not been computed yet" if probability.nil?

        low = Jev.decision_band(above, below)
        return :yes if probability >= above
        return :no if probability <= low

        :unsure
      end
    end
  end
end
