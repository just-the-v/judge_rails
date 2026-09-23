# frozen_string_literal: true

module Judge
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class TransportError < Error; end

  class APIError < Error
    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      @status = status
      @body = body
      super(message)
    end
  end

  class AuthenticationError < APIError; end
  class InvalidRequestError < APIError; end
  class ServerError < APIError; end

  class RateLimitError < APIError
    attr_reader :retry_after

    def initialize(message, status: nil, body: nil, retry_after: nil)
      @retry_after = retry_after
      super(message, status: status, body: body)
    end
  end

  class PayloadTooLargeError < APIError; end

  class InvalidResponseError < Error; end
end
