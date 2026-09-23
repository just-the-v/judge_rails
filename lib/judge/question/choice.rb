# frozen_string_literal: true

module Judge
  class Question
    class Choice < Question
      TYPE = "choice"

      def options
        criteria.keys
      end

      private

      def normalize(criteria)
        options = case criteria
                  when Hash then entries(criteria)
                  when Array then array_options(criteria)
                  else
                    raise ArgumentError,
                          "choice criteria must be an array of options or a hash of option => description"
                  end
        raise ArgumentError, "choice needs at least two options" if options.size < 2

        options
      end

      def array_options(list)
        names = list.map(&:to_s)
        duplicates = names.select { |name| names.count(name) > 1 }.uniq
        raise ArgumentError, "choice options #{duplicates.inspect} appear twice" if duplicates.any?

        names.to_h { |name| [name.dup.freeze, name.tr("_", " ").freeze] }.freeze
      end
    end
  end
end
