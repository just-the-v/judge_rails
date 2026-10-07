# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "zlib"
require "uri"

module Judge
  class Client
    BACKOFF_BASE = 0.25
    BACKOFF_CAP = 8.0
    CONNECTIONS_KEY = :judge_client_connections
    TRANSPORT_ERRORS = [Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
                        Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error].freeze
    UNSAFE_TO_RESEND = [Net::ReadTimeout].freeze
    RETRYABLE_STATUSES = (500..599)

    attr_reader :config
    attr_accessor :sleeper

    def self.close_thread_connections
      store = Thread.current[CONNECTIONS_KEY]
      Thread.current[CONNECTIONS_KEY] = nil
      return unless store && store[:pid] == Process.pid

      store[:connections].each_value do |http|
        http.finish if http.started?
      rescue IOError
        nil
      end
    end

    def inspect
      "#<Judge::Client base_url=#{@config.base_url.inspect} model=#{@config.model.inspect}>"
    end

    def initialize(config: nil, sleeper: nil)
      @config = config || Judge.config
      @sleeper = sleeper || Kernel.method(:sleep)
    end

    def call(state:, questions:, model: nil)
      raise ArgumentError, "state must not be nil" if state.nil?
      raise ArgumentError, "questions must not be empty" if questions.nil? || questions.empty?

      model ||= @config.model
      target = endpoint(model)
      payload = JSON.generate(build_payload(state, questions, model))
      event = { model: model, questions: questions.size, request_bytes: payload.bytesize }

      instrument(event) do
        started = monotonic
        body = unwrap(perform(target, payload))
        set = result_set(body, questions, monotonic - started)
        event[:latency] = set.latency
        event[:input_tokens] = set.usage&.input_tokens
        event[:output_tokens] = set.usage&.output_tokens
        set
      end
    end

    private

    def instrument(event, &)
      return yield unless defined?(::ActiveSupport::Notifications)

      ::ActiveSupport::Notifications.instrument("request.judge", event, &)
    end

    def build_payload(state, questions, model)
      {
        "state" => state,
        "model" => model,
        "questions" => questions.to_h { |name, question| [name.to_s, question.to_payload] }
      }
    end

    def endpoint(_model)
      url = @config.base_url
      @uri = URI.parse(url) if @uri_source != url
      @uri_source = url
      @uri
    end

    def authorization
      "Bearer #{@config.api_key!}"
    end

    def unwrap(body)
      body
    end

    def result_set(body, questions, latency)
      ResultSet.from_response(body, questions: questions, latency: latency)
    end

    def perform(target, payload)
      authorization = self.authorization
      attempt = 0

      loop do
        attempt += 1
        response = attempt_request(target, authorization, payload, attempt)
        next if response.nil?

        status = response.code.to_i
        return parse_body(response) if status < 300

        raise error_for(status, response) unless retryable?(status) && attempt <= @config.max_retries

        pause(retry_delay(response, status, attempt))
      end
    end

    def retry_delay(response, status, attempt)
      after = [429, 503].include?(status) ? retry_after(response) : nil
      raise error_for(status, response) if after && @config.max_retry_wait && after > @config.max_retry_wait

      after || backoff(attempt)
    end

    def attempt_request(target, authorization, payload, attempt)
      started = monotonic
      response = execute(target, authorization, payload)
      log(target, response.code, monotonic - started, attempt)
      response
    rescue *TRANSPORT_ERRORS => e
      close_connection(target)
      log(target, e.class.name, monotonic - started, attempt)
      if attempt > @config.max_retries || UNSAFE_TO_RESEND.any? { |klass| e.is_a?(klass) }
        raise TransportError, "#{e.class}: #{e.message}"
      end

      pause(backoff(attempt))
      nil
    end

    def execute(target, authorization, payload)
      request = Net::HTTP::Post.new(target.request_uri)
      request["Authorization"] = authorization
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = payload
      connection(target).request(request)
    end

    def connection_key(target)
      [target.to_s, @config.open_timeout, @config.timeout].freeze
    end

    def connection(target)
      store = connections
      key = connection_key(target)
      http = store[key]
      return http if http&.started?

      store[key] = start_connection(target)
    end

    def start_connection(target)
      http = Net::HTTP.new(target.host, target.port)
      http.use_ssl = target.scheme == "https"
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout if http.respond_to?(:write_timeout=)
      http.keep_alive_timeout = 30
      http.start
      http
    end

    def connections
      store = Thread.current[CONNECTIONS_KEY]
      unless store && store[:pid] == Process.pid
        store = { pid: Process.pid, connections: {} }
        Thread.current[CONNECTIONS_KEY] = store
      end
      store[:connections]
    end

    def close_connection(target)
      http = connections.delete(connection_key(target))
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
      message = "Judge API returned #{status}: #{error_message(body)}"

      case status
      when 401, 403 then AuthenticationError.new(message, status: status, body: body)
      when 400, 404, 422 then InvalidRequestError.new(message, status: status, body: body)
      when 413 then PayloadTooLargeError.new(message, status: status, body: body)
      when 429
        RateLimitError.new(message, status: status, body: body, retry_after: retry_after(response))
      when RETRYABLE_STATUSES then ServerError.new(message, status: status, body: body)
      else APIError.new(message, status: status, body: body)
      end
    end

    def error_message(body)
      parsed = JSON.parse(body)
      return truncate(body) unless parsed.is_a?(Hash)

      error = parsed["error"]
      message = error.is_a?(Hash) ? error["message"] : error
      (message || parsed["message"] || truncate(body)).to_s
    rescue JSON::ParserError
      truncate(body)
    end

    def truncate(body, limit = 200)
      body.length > limit ? "#{body[0, limit]}..." : body
    end

    def log(target, status, latency, attempt)
      logger = @config.logger
      return unless logger

      logger.debug do
        "Judge POST #{target.path} status=#{status} latency=#{latency.round(3)}s attempt=#{attempt}"
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

Judge::Pool.on_worker_exit { Judge::Client.close_thread_connections }
