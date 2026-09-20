# frozen_string_literal: true

module Jev
  class Question
    class Noul < Question
      private

      def normalize(criteria)
        return nil if criteria.nil?

        unless criteria.is_a?(Hash)
          raise ArgumentError, "noul criteria must be a hash with 'true' and 'false' keys"
        end

        criteria.to_h { |k, v| [k.to_s, v.to_s] }
      end
    end
  end
end
