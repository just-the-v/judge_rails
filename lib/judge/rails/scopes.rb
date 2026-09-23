# frozen_string_literal: true

module Judge
  module Rails
    module Scopes
      extend ActiveSupport::Concern

      MODEL_SCOPES = %i[judge_computed judge_uncomputed].freeze
      DIRECTIONS = %i[asc desc].freeze

      class_methods do
        def judge_scopes!
          return self unless judge_scopes_available?

          judge_attributes.each { |definition| judge_define_scopes(definition) }
          judge_define_model_scopes
          self
        end

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
        end

        def judge_scope_names
          return [] unless judge_scopes_available?

          judge_attributes.flat_map { |definition| judge_scope_names_for(definition) } + MODEL_SCOPES
        end

        private

        def judge_scopes_available?
          singleton_class.method_defined?(:judge_attributes) && !judge_attributes.empty?
        end

        def judge_scope_names_for(definition)
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

        def judge_define_noul_scopes(name, column)
          judge_scope(:"#{name}_above") { |probability| all.where(arel_table[column].gteq(probability)) }
          judge_scope(:"#{name}_below") { |probability| all.where(arel_table[column].lteq(probability)) }
          judge_scope(:"#{name}_between") do |low, high|
            all.where(arel_table[column].gt(low)).where(arel_table[column].lt(high))
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
          return if singleton_class.method_defined?(name)

          singleton_class.define_method(name, &body)
        end

        def judge_value_columns
          judge_attributes.map(&:value_column)
        end

        def judge_order_direction(dir)
          direction = dir.to_s.downcase.to_sym
          return direction if DIRECTIONS.include?(direction)

          raise ArgumentError, "order direction must be one of #{DIRECTIONS.inspect}, got #{dir.inspect}"
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
          by_index = level.is_a?(Integer) && !levels.all? { |label| label.match?(/\A-?\d+\z/) }
          index = by_index ? level : levels.index(level.to_s)
          return index if index&.between?(0, levels.size - 1)

          raise ArgumentError, "unknown #{name} level #{level.inspect}, expected one of #{levels.inspect} " \
                               "or 0..#{levels.size - 1}"
        end

        def method_missing(name, ...)
          if judge_scope_names.include?(name)
            judge_scopes!
            return public_send(name, ...) if singleton_class.method_defined?(name)
          end
          super
        end

        def respond_to_missing?(name, include_private = false)
          judge_scope_names.include?(name) || super
        end
      end
    end
  end
end
