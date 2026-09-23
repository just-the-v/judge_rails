# frozen_string_literal: true

module Judge
  module Decision
    module_function

    def call(probability, above:, below: nil)
      low = band_floor(above, below)
      return :yes if probability >= above
      return :no if probability <= low

      :unsure
    end

    def band_floor(above, below)
      low = below || [(1.0 - above).round(12), above].min
      return low if low <= above

      raise ArgumentError,
            "decide needs below (#{low}) to be at or under above (#{above}), " \
            "otherwise no probability can land in :no or :unsure"
    end
  end
end
