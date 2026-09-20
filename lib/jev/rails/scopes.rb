# frozen_string_literal: true

module Jev
  module Rails
    module Scopes
      extend ActiveSupport::Concern

      MODEL_SCOPES = %i[jev_computed jev_uncomputed].freeze
      DIRECTIONS = %i[asc desc].freeze

      class_methods do
        def jev_scopes!
          return self unless jev_scopes_available?

          jev_attributes.each { |definition| jev_define_scopes(definition) }
          jev_define_model_scopes
          self
        end

        def jev_define_scopes(definition)
          column = definition.value_column
          name = definition.name

          jev_scope(:"#{name}_unknown") { all.where(column => nil) }
          jev_scope(:"order_by_#{name}") { |dir = :desc| all.order(column => jev_order_direction(dir)) }

          case definition.type
          when "noul" then jev_define_noul_scopes(name, column)
          when "choice" then jev_define_choice_scopes(name, column, definition.question.options)
          when "score" then jev_define_score_scopes(name, column, definition.question.levels)
          end
        end

        def jev_scope_names
          return [] unless jev_scopes_available?

          jev_attributes.flat_map { |definition| jev_scope_names_for(definition) } + MODEL_SCOPES
        end

        private

        def jev_scopes_available?
          singleton_class.method_defined?(:jev_attributes) && !jev_attributes.empty?
        end

        def jev_scope_names_for(definition)
          name = definition.name
          suffixes =
            case definition.type
            when "noul" then %w[above below between]
            when "choice" then %w[is not]
            when "score" then %w[at_least at_most level]
            else []
            end
          suffixes.map { |s| :"#{name}_#{s}" } + [:"#{name}_unknown", :"order_by_#{name}"]
        end

        def jev_define_noul_scopes(name, column)
          jev_scope(:"#{name}_above") { |probability| all.where(arel_table[column].gteq(probability)) }
          jev_scope(:"#{name}_below") { |probability| all.where(arel_table[column].lteq(probability)) }
          jev_scope(:"#{name}_between") do |low, high|
            all.where(arel_table[column].gt(low)).where(arel_table[column].lt(high))
          end
        end

        def jev_define_choice_scopes(name, column, options)
          jev_scope(:"#{name}_is") { |*values| all.where(column => jev_options(values, options, name)) }
          jev_scope(:"#{name}_not") { |*values| all.where.not(column => jev_options(values, options, name)) }
        end

        def jev_define_score_scopes(name, column, levels)
          jev_scope(:"#{name}_at_least") do |level|
            all.where(arel_table[column].gteq(jev_level(level, levels, name) - 0.5))
          end
          jev_scope(:"#{name}_at_most") do |level|
            all.where(arel_table[column].lt(jev_level(level, levels, name) + 0.5))
          end
          jev_scope(:"#{name}_level") do |level|
            index = jev_level(level, levels, name)
            all.where(column => (index - 0.5)...(index + 0.5))
          end
        end

        def jev_define_model_scopes
          jev_scope(:jev_computed) do
            jev_value_columns.reduce(all) { |relation, column| relation.where.not(column => nil) }
          end
          jev_scope(:jev_uncomputed) do
            columns = jev_value_columns
            columns.empty? ? all : all.where(columns.map { |c| arel_table[c].eq(nil) }.reduce(:or))
          end
        end

        def jev_scope(name, &body)
          return if singleton_class.method_defined?(name)

          singleton_class.define_method(name, &body)
        end

        def jev_value_columns
          jev_attributes.map(&:value_column)
        end

        def jev_order_direction(dir)
          direction = dir.to_s.downcase.to_sym
          return direction if DIRECTIONS.include?(direction)

          raise ArgumentError, "order direction must be one of #{DIRECTIONS.inspect}, got #{dir.inspect}"
        end

        def jev_options(values, options, name)
          picked = values.flatten.map(&:to_s)
          raise ArgumentError, "#{name} needs at least one option" if picked.empty?

          unknown = picked - options
          return picked if unknown.empty?

          raise ArgumentError,
                "unknown #{name} option(s) #{unknown.inspect}, expected one of #{options.inspect}"
        end

        def jev_level(level, levels, name)
          index = level.is_a?(Integer) ? level : levels.index(level.to_s)
          return index if index&.between?(0, levels.size - 1)

          raise ArgumentError, "unknown #{name} level #{level.inspect}, expected one of #{levels.inspect} " \
                               "or 0..#{levels.size - 1}"
        end

        def method_missing(name, ...)
          if jev_scope_names.include?(name)
            jev_scopes!
            return public_send(name, ...) if singleton_class.method_defined?(name)
          end
          super
        end

        def respond_to_missing?(name, include_private = false)
          jev_scope_names.include?(name) || super
        end
      end
    end
  end
end
