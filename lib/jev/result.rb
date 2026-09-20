# frozen_string_literal: true

module Jev
  class Result
    UNSURE = :unsure

    attr_reader :name, :question, :raw

    def initialize(name:, question:, payload:)
      unless payload.is_a?(Hash)
        raise InvalidResponseError, "expected an answer object for #{name.inspect}, got #{payload.class}"
      end

      @name = name&.to_sym
      @question = question
      @raw = payload.freeze
      freeze
    end

    def type
      raw["type"] || question&.type
    end

    def value
      case type
      when "noul" then number("noul")
      when "choice" then raw.fetch("choice")
      when "score" then number("score")
      else raise InvalidResponseError, "unknown answer type #{type.inspect}"
      end
    end

    def probability
      case type
      when "noul" then number("noul")
      when "choice" then probabilities[value.to_s]
      when "score" then probabilities[level.to_s]
      end
    end

    def confidence
      raw["confidence"]
    end

    def probabilities
      raw["probabilities"] || {}
    end

    def legend
      raw["legend"] || {}
    end

    def level
      return unless type == "score"

      value.round
    end

    def label
      return unless type == "score"

      legend[level.to_s]
    end

    def probability_of(option)
      probabilities[option.to_s]
    end

    def true?(threshold = 0.5)
      raise InvalidResponseError, "true? is only meaningful for noul answers" unless type == "noul"

      value >= threshold
    end

    def confident?(threshold = 0.8)
      (confidence || probability || 0) >= threshold
    end

    def decide(above:, below: nil)
      raise ArgumentError, "decide needs a numeric probability" if probability.nil?

      low = Jev.decision_band(above, below)
      return :yes if probability >= above
      return :no if probability <= low

      UNSURE
    end

    def to_h
      { name: name, type: type, value: value, probability: probability, confidence: confidence }
    end

    def inspect
      "#<Jev::Result #{name.inspect} #{type} value=#{value.inspect} p=#{probability.inspect}>"
    end

    private

    def number(key)
      v = raw[key]
      raise InvalidResponseError, "missing #{key} in answer #{name.inspect}" if v.nil?

      Float(v)
    end
  end
end
