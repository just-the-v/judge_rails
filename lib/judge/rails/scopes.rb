# frozen_string_literal: true

module Judge
  module Rails
    module Scopes
      extend ActiveSupport::Concern

      DIRECTIONS = %i[asc desc].freeze
      NUMERIC_LEVEL = /\A-?\d+\z/

      class_methods do
        def judge_define_scopes(definition)
          column = definition.value_column
          name = definition.name

          judge_scope(:"#{name}_unknown") { all.where(column => nil) }
          judge_scope(:"order_by_#{name}") { |dir = :desc| all.order(column => judge_order_direction(dir)) }

          case definition.type
          when "noul" then judge_define_noul_scopes(name, column)
          when "choice" then judge_define_choice_scopes(name, column, definition.question.options)
          when "score" then judge_define_score_scopes(name, column, definition.question.levels)
          end
          judge_define_model_scopes
        end

        private

        def judge_define_noul_scopes(name, column)
          judge_scope(:"#{name}_above") do |probability|
            all.where(arel_table[column].gteq(judge_probability(probability, name)))
          end
          judge_scope(:"#{name}_below") do |probability|
            all.where(arel_table[column].lteq(judge_probability(probability, name)))
          end
          judge_scope(:"#{name}_between") do |low, high|
            all.where(arel_table[column].gt(judge_probability(low, name)))
               .where(arel_table[column].lt(judge_probability(high, name)))
          end
        end

        def judge_define_choice_scopes(name, column, options)
          judge_scope(:"#{name}_is") { |*values| all.where(column => judge_options(values, options, name)) }
          judge_scope(:"#{name}_not") do |*values|
            all.where.not(column => judge_options(values, options, name))
          end
        end

        def judge_define_score_scopes(name, column, levels)
          judge_scope(:"#{name}_at_least") do |level|
            all.where(arel_table[column].gteq(judge_level(level, levels, name) - 0.5))
          end
          judge_scope(:"#{name}_at_most") do |level|
            all.where(arel_table[column].lt(judge_level(level, levels, name) + 0.5))
          end
          judge_scope(:"#{name}_level") do |level|
            index = judge_level(level, levels, name)
            all.where(column => (index - 0.5)...(index + 0.5))
          end
        end

        def judge_define_model_scopes
          judge_scope(:judge_computed) do
            judge_value_columns.reduce(all) { |relation, column| relation.where.not(column => nil) }
          end
          judge_scope(:judge_uncomputed) do
            columns = judge_value_columns
            columns.empty? ? all : all.where(columns.map { |c| arel_table[c].eq(nil) }.reduce(:or))
          end
        end

        def judge_scope(name, &body)
          generated = (@judge_generated_scopes ||= Set.new)
          return if singleton_class.method_defined?(name, false) && !generated.include?(name)

          generated << name
          singleton_class.send(:define_method, name, &body)
        end

        def judge_value_columns
          judge_attributes.map(&:value_column)
        end

        def judge_order_direction(dir)
          direction = dir.to_s.downcase.to_sym
          return direction if DIRECTIONS.include?(direction)

          raise ArgumentError, "order direction must be one of #{DIRECTIONS.inspect}, got #{dir.inspect}"
        end

        def judge_probability(value, name)
          return value if value.is_a?(Numeric) && value.between?(0, 1)

          raise ArgumentError, "#{name} scopes take a probability between 0 and 1, got #{value.inspect}"
        end

        def judge_options(values, options, name)
          picked = values.flatten.map(&:to_s)
          raise ArgumentError, "#{name} needs at least one option" if picked.empty?

          unknown = picked - options
          return picked if unknown.empty?

          raise ArgumentError,
                "unknown #{name} option(s) #{unknown.inspect}, expected one of #{options.inspect}"
        end

        def judge_level(level, levels, name)
          by_index = level.is_a?(Integer) && !levels.all? { |label| label.match?(NUMERIC_LEVEL) }
          index = by_index ? level : levels.index(level.to_s)
          return index if index&.between?(0, levels.size - 1)

          raise ArgumentError, "unknown #{name} level #{level.inspect}, expected one of #{levels.inspect} " \
                               "or 0..#{levels.size - 1}"
        end
      end
    end
  end
end
