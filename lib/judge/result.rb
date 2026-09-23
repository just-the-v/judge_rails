# frozen_string_literal: true

module Judge
  class Result
    UNSURE = :unsure

    TYPES = %w[noul choice score].freeze

    attr_reader :name, :question, :raw, :type, :value, :probability

    def self.from_values(name:, type:, value:, question: nil, confidence: nil,
                         probabilities: nil, legend: nil)
      kind = type.to_s
      payload = { "type" => kind, kind => value }
      payload["confidence"] = confidence unless confidence.nil?
      payload["probabilities"] = probabilities.to_h { |k, v| [k.to_s, v] } if probabilities
      payload["legend"] = legend.to_h { |k, v| [k.to_s, v] } if legend
      new(name: name, question: question, payload: payload)
    end

    def self.frozen_copy(value)
      case value
      when Hash then value.to_h { |k, v| [frozen_copy(k), frozen_copy(v)] }.freeze
      when Array then value.map { |v| frozen_copy(v) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    def initialize(name:, question:, payload:)
      unless payload.is_a?(Hash)
        raise InvalidResponseError, "expected an answer object for #{name.inspect}, got #{payload.class}"
      end

      @name = name&.to_sym
      @question = question
      @raw = self.class.frozen_copy(payload)
      @type = resolve_type
      check_shape!
      @value = parse_value
      @probability = compute_probability
      freeze
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
      unless type == "noul"
        raise ArgumentError,
              "true? is only meaningful for noul answers, this is a #{type}"
      end

      value >= threshold
    end

    def confident?(threshold = 0.8)
      (confidence || probability || 0) >= threshold
    end

    def decide(above:, below: nil)
      raise ArgumentError, "decide needs a numeric probability" if probability.nil?

      Decision.call(probability, above: above, below: below)
    end

    def to_h
      { name: name, type: type, value: value, probability: probability, confidence: confidence }
    end

    def inspect
      "#<Judge::Result #{name.inspect} #{type} value=#{value.inspect} p=#{probability.inspect}>"
    end

    private

    def resolve_type
      kind = raw["type"] || question&.type
      unless TYPES.include?(kind)
        raise InvalidResponseError,
              "unknown answer type #{kind.inspect} for #{name.inspect}"
      end
      if question && question.type != kind
        raise InvalidResponseError, "a #{question.type} question got a #{kind} answer for #{name.inspect}"
      end

      kind
    end

    def check_shape!
      unless raw["probabilities"].nil? || raw["probabilities"].is_a?(Hash)
        raise InvalidResponseError, "probabilities for #{name.inspect} must be an object"
      end
      unless raw["legend"].nil? || raw["legend"].is_a?(Hash)
        raise InvalidResponseError, "legend for #{name.inspect} must be an object"
      end
      return if raw["confidence"].nil? || raw["confidence"].is_a?(Numeric)

      raise InvalidResponseError, "confidence for #{name.inspect} must be a number"
    end

    def parse_value
      case type
      when "noul" then number("noul")
      when "choice" then choice_value
      when "score" then score_value
      end
    end

    def compute_probability
      case type
      when "noul" then value
      when "choice" then probabilities[value]
      when "score" then probabilities[level.to_s]
      end
    end

    def choice_value
      choice = raw["choice"]
      raise InvalidResponseError, "missing choice in answer #{name.inspect}" unless choice.is_a?(String)
      if question.respond_to?(:options) && !question.options.include?(choice)
        raise InvalidResponseError, "#{choice.inspect} is not an option of #{name.inspect}"
      end

      choice
    end

    def score_value
      score = number("score")
      if question.respond_to?(:max_level) && !score.between?(0, question.max_level)
        raise InvalidResponseError, "score #{score} for #{name.inspect} is outside 0..#{question.max_level}"
      end

      score
    end

    def number(key)
      v = raw[key]
      raise InvalidResponseError, "missing #{key} in answer #{name.inspect}" if v.nil?
      unless v.is_a?(Numeric)
        raise InvalidResponseError,
              "#{key} in answer #{name.inspect} is not a number: #{v.inspect}"
      end

      Float(v)
    end
  end
end
