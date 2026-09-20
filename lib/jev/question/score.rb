# frozen_string_literal: true

module Jev
  class Question
    class Score < Question
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

        levels.map(&:to_s)
      end
    end
  end
end
