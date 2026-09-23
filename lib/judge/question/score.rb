# frozen_string_literal: true

module Judge
  class Question
    class Score < Question
      TYPE = "score"

      def levels
        criteria
      end

      def max_level
        criteria.size - 1
      end

      private

      def normalize(criteria)
        levels = criteria.is_a?(Range) ? criteria.to_a : criteria
        unless levels.is_a?(Array)
          raise ArgumentError,
                "score criteria must be an array or range of ordered levels"
        end
        raise ArgumentError, "score needs at least two levels" if levels.size < 2
        unless levels.all? { |level| level.is_a?(String) || level.is_a?(Symbol) || level.is_a?(Numeric) }
          raise ArgumentError, "score levels must be strings, symbols or numbers"
        end

        labels = levels.map { |level| level.to_s.dup.freeze }
        raise ArgumentError, "score levels must be distinct" if labels.uniq.size != labels.size

        labels.freeze
      end
    end
  end
end
