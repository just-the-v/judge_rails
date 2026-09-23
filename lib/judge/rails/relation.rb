# frozen_string_literal: true

module Judge
  module Rails
    module Relation
      ADHOC_NAME = :judge_adhoc

      Target = Struct.new(:question, :option, :level) do
        def measure(result)
          case question.type
          when "choice" then result.probability_of(option) || 0.0
          else result.value
          end
        end

        def passes?(result, threshold)
          return result.value >= level - 0.5 if question.type == "score"

          measure(result) >= threshold
        end
      end

      module ClassMethods
        def judge_filter(question, limit: nil, source: nil, threshold: 0.5, option: nil, at_least: nil,
                         model: nil, adapter: nil, concurrency: nil)
          question = judge_adhoc_question(question)
          target = judge_target(question, :judge_filter, option: option, at_least: at_least)
          judge_check_threshold!(threshold)
          judged = judge_judge(question, :judge_filter, limit: limit, source: source, model: model,
                                                        adapter: adapter, concurrency: concurrency)
          judged.select { |_record, result| target.passes?(result, threshold) }.keys
        end

        def judge_map(question, limit: nil, source: nil, model: nil, adapter: nil, concurrency: nil)
          judge_judge(judge_adhoc_question(question), :judge_map, limit: limit, source: source, model: model,
                                                                  adapter: adapter, concurrency: concurrency)
        end

        def judge_sort(question, limit: nil, source: nil, dir: :desc, option: nil, model: nil, adapter: nil,
                       concurrency: nil)
          direction = dir.to_s.downcase.to_sym
          unless %i[asc desc].include?(direction)
            raise ArgumentError, "dir must be :asc or :desc, got #{dir.inspect}"
          end

          question = judge_adhoc_question(question)
          target = judge_target(question, :judge_sort, option: option, at_least: :any)
          judged = judge_judge(question, :judge_sort, limit: limit, source: source, model: model,
                                                      adapter: adapter, concurrency: concurrency)
          sign = direction == :asc ? 1 : -1
          judged.sort_by { |_record, result| sign * target.measure(result) }.map(&:first)
        end

        private

        def judge_adhoc_question(question)
          question.is_a?(Judge::Question) ? question : Judge.noul(question.to_s)
        end

        def judge_target(question, caller_name, option:, at_least:)
          case question.type
          when "choice" then Target.new(question, judge_target_option(question, option, caller_name), nil)
          when "score" then Target.new(question, nil, judge_target_level(question, at_least, caller_name))
          else Target.new(question, nil, nil)
          end
        end

        def judge_target_option(question, option, caller_name)
          return option.to_s if question.options.include?(option.to_s)

          raise ArgumentError, "#{caller_name} with a choice question needs option: one of " \
                               "#{question.options.inspect}, got #{option.inspect}"
        end

        def judge_target_level(question, at_least, caller_name)
          return nil if at_least == :any

          if at_least.nil?
            raise ArgumentError, "#{caller_name} with a score question needs at_least: one of " \
                                 "#{question.levels.inspect}"
          end
          judge_level(at_least, question.levels, caller_name)
        end

        def judge_check_threshold!(threshold)
          return if threshold.is_a?(Numeric) && threshold.between?(0, 1)

          raise ArgumentError, "threshold must be a number between 0 and 1, got #{threshold.inspect}"
        end

        def judge_judge(question, caller_name, limit:, source:, model:, adapter:, concurrency:)
          judge_check_limit!(limit, caller_name)
          definition = Definition.new(name: ADHOC_NAME, question: question,
                                      source: judge_adhoc_source(source, caller_name))

          records = all.limit([all.limit_value&.then { |value| Integer(value) }, limit].compact.min).to_a
          # Built here so the workers below never check out a database connection.
          judgeable = records.map { |record| [record, definition.state_for(record)] }
                             .reject { |_record, state| state.empty? }

          texts = judgeable.map(&:last).uniq
          answers = Judge::Pool.map(texts, concurrency: concurrency) do |text|
            Judge.ask(definition.question, text: text, model: model, adapter: adapter)
          end
          by_text = texts.zip(answers).to_h

          judgeable.to_h { |record, state| [record, by_text.fetch(state)] }
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
    end
  end
end
