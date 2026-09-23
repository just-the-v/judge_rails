# frozen_string_literal: true

module Judge
  class ResultSet
    include Enumerable

    Usage = Struct.new(:input_tokens, :output_tokens) do
      def total
        input_tokens.to_i + output_tokens.to_i
      end
    end

    attr_reader :model, :usage, :latency, :raw

    def initialize(results, model: nil, usage: nil, latency: nil, raw: nil)
      @results = results.to_h { |r| [r.name, r] }.freeze
      raise ArgumentError, "duplicate result names" if @results.size != results.size

      @model = model
      @usage = usage
      @latency = latency
      @raw = raw
      freeze
    end

    def self.from_response(body, questions:, latency: nil)
      answers = body["answers"]
      raise InvalidResponseError, "response has no answers" unless answers.is_a?(Hash)

      results = questions.map do |name, question|
        payload = answers[name.to_s]
        raise InvalidResponseError, "no answer for #{name.inspect}" if payload.nil?

        question.coerce(payload, name: name)
      end

      usage = parse_usage(body["usage"])
      new(results, model: body["model"], usage: usage, latency: latency, raw: body)
    end

    def self.parse_usage(raw)
      return unless raw.is_a?(Hash)

      Usage.new(raw["input_tokens"], raw["output_tokens"]).freeze
    end

    def [](name)
      @results[name.to_sym]
    end

    def fetch(name)
      @results.fetch(name.to_sym)
    end

    def each(&)
      @results.each_value(&)
    end

    def names
      @results.keys
    end

    def size
      @results.size
    end

    def to_h
      @results.transform_values(&:to_h)
    end

    def inspect
      "#<Judge::ResultSet #{@results.keys.inspect} model=#{model.inspect} latency=#{latency&.round(3)}>"
    end
  end
end
