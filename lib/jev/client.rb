# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Jev
  class Client
    BACKOFF_BASE = 0.25
    BACKOFF_CAP = 8.0
    CONNECTIONS_KEY = :jev_client_connections
    TRANSPORT_ERRORS = [Timeout::Error, SocketError, IOError, Errno::ECONNRESET,
                        Errno::ECONNREFUSED, Errno::EPIPE, Errno::EHOSTUNREACH].freeze
    RETRYABLE_STATUSES = (500..599)

    attr_reader :config
    attr_accessor :sleeper

    def initialize(config: nil, sleeper: nil)
      @config = config || Jev.config
      @sleeper = sleeper || Kernel.method(:sleep)
      @uri = URI.parse(@config.base_url)
    end

    def call(state:, questions:, model: nil)
      raise ArgumentError, "state must not be nil" if state.nil?
      raise ArgumentError, "questions must not be empty" if questions.nil? || questions.empty?

      payload = JSON.generate(build_payload(state, questions, model))
      started = monotonic
      body = perform(payload)
      ResultSet.from_response(body, questions: questions, latency: monotonic - started)
    end

    private

    def build_payload(state, questions, model)
      {
        "state" => state,
        "model" => model || @config.model,
        "questions" => questions.to_h { |name, question| [name.to_s, question.to_payload] }
      }
    end

    def perform(payload)
      authorization = "Bearer #{@config.api_key!}"
      attempt = 0

      loop do
        attempt += 1
        response = attempt_request(authorization, payload, attempt)
        next if response.nil?

        status = response.code.to_i
        return parse_body(response) if status < 300

        raise error_for(status, response) unless retryable?(status) && attempt <= @config.max_retries

        pause(retry_delay(response, status, attempt))
      end
    end

    def attempt_request(authorization, payload, attempt)
      started = monotonic
      response = execute(authorization, payload)
      log(response.code, monotonic - started, attempt)
      response
    rescue *TRANSPORT_ERRORS => e
      close_connection
      log(e.class.name, monotonic - started, attempt)
      raise TransportError, "#{e.class}: #{e.message}" if attempt > @config.max_retries

      pause(backoff(attempt))
      nil
    end

    def execute(authorization, payload)
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Authorization"] = authorization
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = payload
      connection.request(request)
    end

    def connection
      store = (Thread.current[CONNECTIONS_KEY] ||= {})
      http = store[@config.base_url]
      return http if http&.started?

      store[@config.base_url] = start_connection
    end

    def start_connection
      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = @uri.scheme == "https"
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30
      http.start
      http
    end

    def close_connection
      store = Thread.current[CONNECTIONS_KEY]
      http = store&.delete(@config.base_url)
      http.finish if http&.started?
    rescue IOError
      nil
    end

    def parse_body(response)
      body = response.body.to_s
      parsed = JSON.parse(body)
      raise InvalidResponseError, "expected a JSON object, got #{parsed.class}" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise InvalidResponseError, "could not parse response body: #{e.message}"
    end

    def retryable?(status)
      status == 429 || RETRYABLE_STATUSES.cover?(status)
    end

    def retry_delay(response, status, attempt)
      after = status == 429 ? retry_after(response) : nil
      after || backoff(attempt)
    end

    def retry_after(response)
      value = response["Retry-After"]
      return nil if value.nil?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end

    def backoff(attempt)
      window = [BACKOFF_BASE * (2**(attempt - 1)), BACKOFF_CAP].min
      window * (0.5 + (rand * 0.5))
    end

    def pause(seconds)
      @sleeper.call(seconds) if seconds.positive?
    end

    def error_for(status, response)
      body = response.body.to_s
      message = "Jev API returned #{status}: #{error_message(body)}"

      case status
      when 401, 403 then AuthenticationError.new(message, status: status, body: body)
      when 400, 404, 422 then InvalidRequestError.new(message, status: status, body: body)
      when 429
        RateLimitError.new(message, status: status, body: body, retry_after: retry_after(response))
      when RETRYABLE_STATUSES then ServerError.new(message, status: status, body: body)
      else APIError.new(message, status: status, body: body)
      end
    end

    def error_message(body)
      parsed = JSON.parse(body)
      error = parsed["error"]
      (error.is_a?(Hash) ? error["message"] : error) || parsed["message"] || truncate(body)
    rescue JSON::ParserError
      truncate(body)
    end

    def truncate(body, limit = 200)
      body.length > limit ? "#{body[0, limit]}..." : body
    end

    def log(status, latency, attempt)
      logger = @config.logger
      return unless logger

      logger.debug do
        "Jev POST #{@uri.path} status=#{status} latency=#{latency.round(3)}s attempt=#{attempt}"
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
