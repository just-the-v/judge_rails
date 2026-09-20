# frozen_string_literal: true

module Jev
  class Configuration
    DEFAULT_BASE_URL = "https://api.typesafe.ai/v1/systemone"
    DEFAULT_MODEL = "jev-latest"

    attr_accessor :api_key, :base_url, :model, :timeout, :open_timeout, :max_retries, :logger

    def initialize
      @api_key = ENV.fetch("JEV_API_KEY", nil) || ENV.fetch("TYPESAFE_API_KEY", nil)
      @base_url = ENV.fetch("JEV_BASE_URL", DEFAULT_BASE_URL)
      @model = ENV.fetch("JEV_MODEL", DEFAULT_MODEL)
      @timeout = 10.0
      @open_timeout = 5.0
      @max_retries = 2
      @logger = nil
    end

    def api_key!
      return @api_key if @api_key && !@api_key.empty?

      raise ConfigurationError, "No Jev API key. Set JEV_API_KEY or Jev.configure { |c| c.api_key = ... }"
    end
  end
end
