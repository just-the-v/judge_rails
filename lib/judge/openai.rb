# frozen_string_literal: true

require "judge/client"

module Judge
  # OpenAI's Decisions API. A different wire format from Jev, so the answers are rebuilt from typed
  # values with Result.from_values.
  class OpenAI < Client
    MODELS = %w[gpt-6-luna].freeze
    URL = "https://api.openai.com/v1/decisions"
    QUESTION_TYPES = { "noul" => "predicate", "choice" => "choice", "score" => "score" }.freeze

    def initialize(config: nil, sleeper: nil, url: URL)
      super(config: config, sleeper: sleeper)
      @url = URI.parse(url)
    end

    def inspect
      "#<Judge::OpenAI model=#{@config.model.inspect}>"
    end

    private

    def endpoint(model)
      return @url if MODELS.include?(model)

      raise ConfigurationError, "OpenAI decisions serve #{MODELS.join(", ")}, not #{model.inspect}. " \
                                "Set config.model or pass model: \"#{MODELS.first}\""
    end

    def authorization
      "Bearer #{@config.openai_api_key!}"
    end

    def build_payload(state, questions, model)
      {
        "model" => model,
        "input" => state.is_a?(String) ? state : JSON.generate(state),
        "questions" => questions.map { |name, question| question_payload(name, question) }
      }
    end

    def question_payload(name, question)
      payload = { "type" => QUESTION_TYPES.fetch(question.type), "name" => name.to_s,
                  "instructions" => question.instructions }
      case question.type
      when "noul"
        payload["instructions"] += "\n\nCriteria: #{JSON.generate(question.criteria)}" if question.criteria
      when "choice"
        payload["choices"] = question.criteria.map { |value, about| choice_payload(value, about) }
      when "score"
        payload["levels"] = question.levels.map { |label| { "label" => label } }
      end
      payload
    end

    def choice_payload(value, about)
      option = { "value" => value }
      description = about.is_a?(String) ? about : JSON.generate(about)
      option["description"] = description unless about.nil? || description.empty?
      option
    end

    def result_set(body, questions, latency)
      answers = body["answers"]
      raise InvalidResponseError, "response has no answers" unless answers.is_a?(Array)

      by_name = answers.grep(Hash).to_h { |answer| [answer["name"].to_s, answer] }
      results = questions.map do |name, question|
        answer = by_name[name.to_s]
        raise InvalidResponseError, "no answer for #{name.inspect}" if answer.nil?

        result(name, question, answer)
      end
      ResultSet.new(results, model: body["model"], usage: ResultSet.parse_usage(body["usage"]),
                             latency: latency, raw: body)
    end

    def result(name, question, answer)
      kind = answer["type"]
      raise RefusalError.new(question_name: name) if kind == "refusal"
      unless kind == QUESTION_TYPES[question.type]
        raise InvalidResponseError,
              "a #{question.type} question got a #{kind.inspect} answer for #{name.inspect}"
      end

      Result.from_values(name: name, question: question, type: question.type, **values(question, answer))
    end

    def values(question, answer)
      case question.type
      when "noul" then { value: answer["probability"] }
      when "choice"
        { value: answer["choice"], confidence: answer["confidence"], probabilities: distribution(answer) }
      when "score"
        { value: answer["score"], confidence: answer["confidence"], probabilities: distribution(answer),
          legend: rows(answer).to_h { |level| [level["value"].to_s, level["label"]] } }
      end
    end

    def distribution(answer)
      rows(answer).to_h { |option| [option["value"].to_s, option["probability"]] }
    end

    def rows(answer)
      list = answer["probabilities"]
      return list if list.is_a?(Array) && list.all?(Hash)

      raise InvalidResponseError, "probabilities for #{answer["name"].inspect} must be a list of objects"
    end
  end
end
