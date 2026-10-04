# frozen_string_literal: true

require "judge/client"

module Judge
  # Cloudflare's Clef on Workers AI. Same request and answers as Jev, behind a Cloudflare envelope
  # and an account-scoped URL.
  class Clef < Client
    MODELS = %w[clef clef-flash].freeze
    API_ROOT = "https://api.cloudflare.com/client/v4"

    def initialize(config: nil, sleeper: nil, api_root: API_ROOT)
      super(config: config, sleeper: sleeper)
      @api_root = api_root.to_s.chomp("/")
    end

    def inspect
      "#<Judge::Clef model=#{@config.model.inspect}>"
    end

    private

    def endpoint(model)
      unless MODELS.include?(model)
        raise ConfigurationError, "Clef serves #{MODELS.join(" and ")}, not #{model.inspect}. " \
                                  "Set config.model or pass model: \"clef\""
      end

      URI.parse("#{@api_root}/accounts/#{@config.cloudflare_account_id!}/ai/run/@cf/cloudflare/#{model}")
    end

    def authorization
      "Bearer #{@config.cloudflare_api_token!}"
    end

    def unwrap(body)
      result = body["result"]
      return result if body["success"] != false && result.is_a?(Hash)

      raise InvalidResponseError, "Cloudflare returned no result: #{error_message(JSON.generate(body))}"
    end

    def error_message(body)
      parsed = JSON.parse(body)
      errors = parsed["errors"] if parsed.is_a?(Hash)
      message = errors.first["message"] if errors.is_a?(Array) && errors.first.is_a?(Hash)
      message ? message.to_s : super
    rescue JSON::ParserError
      super
    end
  end
end
