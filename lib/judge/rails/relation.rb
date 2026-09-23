# frozen_string_literal: true

module Judge
  module Rails
    module Relation
      ADHOC_NAME = :judge_adhoc

      module ClassMethods
        def judge_filter(question, limit: nil, source: nil, threshold: 0.5, model: nil, adapter: nil,
                         concurrency: nil)
          judged = judge_judge(question, :judge_filter, limit: limit, source: source, model: model,
                                                        adapter: adapter, concurrency: concurrency)
          judged.select { |_record, result| Relation.passes?(result, threshold) }.keys
        end

        def judge_map(question, limit: nil, source: nil, model: nil, adapter: nil, concurrency: nil)
          judge_judge(question, :judge_map, limit: limit, source: source, model: model, adapter: adapter,
                                            concurrency: concurrency)
        end

        def judge_sort(question, limit: nil, source: nil, dir: :desc, model: nil, adapter: nil,
                       concurrency: nil)
          direction = dir.to_s.downcase.to_sym
          unless %i[asc desc].include?(direction)
            raise ArgumentError, "dir must be :asc or :desc, got #{dir.inspect}"
          end

          judged = judge_judge(question, :judge_sort, limit: limit, source: source, model: model,
                                                      adapter: adapter, concurrency: concurrency)
          sign = direction == :asc ? 1 : -1
          judged.sort_by { |_record, result| sign * Relation.rank(result) }.map(&:first)
        end

        private

        def judge_judge(question, caller_name, limit:, source:, model:, adapter:, concurrency:)
          judge_check_limit!(limit, caller_name)
          definition = Definition.new(
            name: ADHOC_NAME,
            question: question.is_a?(Judge::Question) ? question : Judge.noul(question.to_s),
            source: judge_adhoc_source(source, caller_name)
          )

          records = all.limit([all.limit_value, limit].compact.min).to_a
          # Built here so the workers below never check out a database connection.
          judgeable = records.map { |record| [record, definition.state_for(record)] }
                             .reject { |_record, state| state.empty? }

          states = judgeable.map(&:last)
          results = Judge::Pool.map(states, concurrency: judge_concurrency(concurrency)) do |state|
            Judge.ask(definition.question, text: state, model: model, adapter: adapter)
          end

          judgeable.map(&:first).zip(results).to_h
        end

        def judge_concurrency(override)
          override || Judge.config.concurrency || Judge::Pool::DEFAULT_CONCURRENCY
        end

        def judge_check_limit!(limit, caller_name)
          if limit.nil?
            raise ArgumentError,
                  "#{caller_name} requires limit:. It makes one API call per row, so an unbounded " \
                  "scan would judge the whole table. Pass an explicit limit: you are willing to pay for."
          end
          return if limit.is_a?(Integer) && limit.positive?

          raise ArgumentError, "limit: must be a positive Integer, got #{limit.inspect}"
        end

        def judge_adhoc_source(source, caller_name)
          resolved = source || (respond_to?(:judge_default_source) && judge_default_source)
          return resolved if resolved

          raise ArgumentError,
                "#{caller_name} needs source: (a column symbol or a callable returning the text to judge), " \
                "or a model-level judge_source"
        end
      end

      def self.passes?(result, threshold)
        score = result.type == "noul" ? result.value : (result.probability || result.confidence)
        !score.nil? && score >= threshold
      end

      def self.rank(result)
        value = result.value
        return value.to_f if value.is_a?(Numeric)

        (result.probability || result.confidence || 0).to_f
      end
    end
  end
end
