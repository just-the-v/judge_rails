# frozen_string_literal: true

module Jev
  module Rails
    module Relation
      ADHOC_NAME = :jev_adhoc

      module ClassMethods
        def jev_filter(question, limit: nil, source: nil, threshold: 0.5, model: nil, client: nil)
          judged = jev_judge(question, :jev_filter, limit: limit, source: source, model: model,
                                                    client: client)
          judged.select { |_record, result| Relation.passes?(result, threshold) }.keys
        end

        def jev_map(question, limit: nil, source: nil, model: nil, client: nil)
          jev_judge(question, :jev_map, limit: limit, source: source, model: model, client: client)
        end

        def jev_sort(question, limit: nil, source: nil, dir: :desc, model: nil, client: nil)
          direction = dir.to_s.downcase.to_sym
          unless %i[asc desc].include?(direction)
            raise ArgumentError, "dir must be :asc or :desc, got #{dir.inspect}"
          end

          judged = jev_judge(question, :jev_sort, limit: limit, source: source, model: model, client: client)
          sign = direction == :asc ? 1 : -1
          judged.sort_by { |_record, result| sign * Relation.rank(result) }.map(&:first)
        end

        private

        def jev_judge(question, caller_name, limit:, source:, model:, client:)
          jev_check_limit!(limit, caller_name)
          definition = Definition.new(
            name: ADHOC_NAME,
            question: question.is_a?(Jev::Question) ? question : Jev.noul(question.to_s),
            source: jev_adhoc_source(source, caller_name)
          )

          all.limit(limit).to_a.to_h do |record|
            state = definition.state_for(record)
            [record, Jev.ask(definition.question, text: state, model: model, client: client)]
          end
        end

        def jev_check_limit!(limit, caller_name)
          if limit.nil?
            raise ArgumentError,
                  "#{caller_name} requires limit:. It makes one API call per row, so an unbounded " \
                  "scan would judge the whole table. Pass an explicit limit: you are willing to pay for."
          end
          return if limit.is_a?(Integer) && limit.positive?

          raise ArgumentError, "limit: must be a positive Integer, got #{limit.inspect}"
        end

        def jev_adhoc_source(source, caller_name)
          resolved = source || (respond_to?(:jev_default_source) && jev_default_source)
          return resolved if resolved

          raise ArgumentError,
                "#{caller_name} needs source: (a column symbol or a callable returning the text to judge), " \
                "or a model-level jev_source"
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
