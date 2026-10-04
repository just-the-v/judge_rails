# frozen_string_literal: true

module Judge
  class Configuration
    DEFAULT_BASE_URL = "https://api.typesafe.ai/v1/systemone"
    DEFAULT_MODEL = "jev-latest"
    CLEF_DEFAULT_MODEL = "clef"

    attr_reader :api_key, :base_url, :timeout, :open_timeout, :max_retries, :max_retry_wait,
                :concurrency, :adapter, :cloudflare_api_token, :cloudflare_account_id
    attr_accessor :logger

    def initialize
      self.api_key = [ENV.fetch("JEV_API_KEY", nil), ENV.fetch("TYPESAFE_API_KEY", nil)]
                     .find { |value| !blank?(value) }
      self.base_url = present_env("JEV_BASE_URL") || DEFAULT_BASE_URL
      @model = present_env("JEV_MODEL")
      self.cloudflare_api_token = ENV.fetch("CLOUDFLARE_API_TOKEN", nil)
      self.cloudflare_account_id = ENV.fetch("CLOUDFLARE_ACCOUNT_ID", nil)
      self.timeout = 10.0
      self.open_timeout = 5.0
      self.max_retries = 2
      self.max_retry_wait = 10.0
      self.concurrency = nil
      self.adapter = present_env("JUDGE_ADAPTER") || :jev
      @logger = nil
    end

    def api_key=(value)
      @api_key = blank?(value) ? nil : value.to_s.strip
    end

    def base_url=(value)
      raise ArgumentError, "base_url must not be blank" if blank?(value)

      @base_url = value.to_s.strip
    end

    def cloudflare_api_token=(value)
      @cloudflare_api_token = blank?(value) ? nil : value.to_s.strip
    end

    def cloudflare_account_id=(value)
      @cloudflare_account_id = blank?(value) ? nil : value.to_s.strip
    end

    def model
      @model || (@adapter == :clef ? CLEF_DEFAULT_MODEL : DEFAULT_MODEL)
    end

    def model=(value)
      raise ArgumentError, "model must not be blank" if blank?(value)

      @model = value.to_s.strip
    end

    def timeout=(value)
      @timeout = positive_number(value, "timeout")
    end

    def open_timeout=(value)
      @open_timeout = positive_number(value, "open_timeout")
    end

    def max_retries=(value)
      unless value.is_a?(Integer) && !value.negative?
        raise ArgumentError, "max_retries must be an Integer of 0 or more, got #{value.inspect}"
      end

      @max_retries = value
    end

    def max_retry_wait=(value)
      @max_retry_wait = value.nil? ? nil : positive_number(value, "max_retry_wait")
    end

    def concurrency=(value)
      unless value.nil? || (value.is_a?(Integer) && value.positive?)
        raise ArgumentError, "concurrency must be nil or a positive Integer, got #{value.inspect}"
      end

      @concurrency = value
    end

    def adapter=(value)
      @adapter = value.respond_to?(:call) ? value : value.to_s.strip.to_sym
    end

    def api_key!
      return @api_key if @api_key

      raise ConfigurationError, "No Judge API key. Set JEV_API_KEY or Judge.configure { |c| c.api_key = ... }"
    end

    def cloudflare_api_token!
      return @cloudflare_api_token if @cloudflare_api_token

      raise ConfigurationError, "No Cloudflare API token. Set CLOUDFLARE_API_TOKEN or " \
                                "Judge.configure { |c| c.cloudflare_api_token = ... }"
    end

    def cloudflare_account_id!
      return @cloudflare_account_id if @cloudflare_account_id

      raise ConfigurationError, "No Cloudflare account id. Set CLOUDFLARE_ACCOUNT_ID or " \
                                "Judge.configure { |c| c.cloudflare_account_id = ... }"
    end

    def inspect
      key = @api_key ? "[FILTERED]" : "nil"
      token = @cloudflare_api_token ? "[FILTERED]" : "nil"
      "#<Judge::Configuration api_key=#{key} cloudflare_api_token=#{token} base_url=#{@base_url.inspect} " \
        "model=#{model.inspect} adapter=#{@adapter.inspect}>"
    end

    private

    def present_env(name)
      value = ENV.fetch(name, nil)
      blank?(value) ? nil : value.strip
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def positive_number(value, label)
      return value.to_f if value.is_a?(Numeric) && value.positive?

      raise ArgumentError, "#{label} must be a positive number of seconds, got #{value.inspect}"
    end
  end
end
