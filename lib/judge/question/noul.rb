# frozen_string_literal: true

module Judge
  class Question
    class Noul < Question
      TYPE = "noul"
      KEYS = %w[true false].freeze

      private

      def normalize(criteria)
        return nil if criteria.nil?

        unless criteria.is_a?(Hash) && criteria.keys.map(&:to_s).sort == KEYS.sort
          raise ArgumentError, "noul criteria must be a hash with exactly 'true' and 'false' keys"
        end

        entries(criteria)
      end
    end
  end
end
