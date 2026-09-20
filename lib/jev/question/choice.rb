# frozen_string_literal: true

module Jev
  class Question
    class Choice < Question
      def options
        criteria.keys
      end

      private

      def normalize(criteria)
        case criteria
        when Hash
          raise ArgumentError, "choice needs at least two options" if criteria.size < 2

          criteria.to_h { |k, v| [k.to_s, v.to_s] }
        when Array
          raise ArgumentError, "choice needs at least two options" if criteria.size < 2

          criteria.to_h { |o| [o.to_s, o.to_s.tr("_", " ")] }
        else
          raise ArgumentError,
                "choice criteria must be an array of options or a hash of option => description"
        end
      end
    end
  end
end
