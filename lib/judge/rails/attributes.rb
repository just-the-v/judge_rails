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
      rescue StandardError
        judge_persist_after_failure(done) if done.any?
        raise
      else
        judge_persist_judgments(done, adapter: adapter) if done.any?
        done.map(&:name)
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

      def judge_persist_judgments(definitions, adapter: nil, inline: true)
        return judge_create_with_judgments(adapter, inline) if new_record?

        run_callbacks(:judge_refresh) do
          next if update_columns(judge_columns_to_store(definitions))

          raise ActiveRecord::RecordNotFound.new(
            "#{self.class} #{id.inspect} no longer exists, so its new judgments were not stored",
            self.class.name, self.class.primary_key, id
          )
        end
      end

      def judge_persist_after_failure(definitions)
        judge_persist_judgments(definitions, inline: false)
      rescue StandardError => e
        Judge::Rails.log_failure(self.class, e)
      end

      def judge_columns_to_store(definitions)
        columns = definitions.flat_map { |d| [d.value_column, d.sidecar_column] }
                             .to_h { |c| [c, read_attribute(c)] }
        now = current_time_from_proper_timezone
        self.class.timestamp_attributes_for_update_in_model.each { |column| columns[column.to_sym] = now }
        columns
      end

      def judge_create_with_judgments(adapter, inline)
        @judge_refresh_adapter = adapter
        @judge_skip_inline = !inline
        run_callbacks(:judge_refresh) { save! }
      ensure
        @judge_refresh_adapter = nil
        @judge_skip_inline = nil
      end
    end
  end
end
