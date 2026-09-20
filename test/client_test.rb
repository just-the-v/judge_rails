# frozen_string_literal: true

require "test_helper"
require "jev/client"
require "socket"

class StubServer
  Request = Struct.new(:http_method, :path, :headers, :body) do
    def json
      JSON.parse(body)
    end
  end

  attr_reader :requests

  def initialize(&handler)
    @handler = handler
    @server = TCPServer.new("127.0.0.1", 0)
    @requests = []
    @connections = 0
    @mutex = Mutex.new
    @threads = []
    @accepter = Thread.new { accept_loop }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}/v1/systemone"
  end

  def connections
    @mutex.synchronize { @connections }
  end

  def shutdown
    @accepter.kill
    @threads.each(&:kill)
    @server.close unless @server.closed?
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @mutex.synchronize { @connections += 1 }
      @threads << Thread.new { serve(socket) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    while (request = read_request(socket))
      index = @mutex.synchronize do
        @requests << request
        @requests.size - 1
      end
      status, headers, body = @handler.call(request, index)
      write_response(socket, status, headers, body)
    end
  rescue StandardError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    line = socket.gets
    return nil if line.nil?

    method, path, = line.split
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      key, value = header.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    Request.new(method, path, headers, length.positive? ? socket.read(length) : "")
  end

  def write_response(socket, status, headers, body)
    out = "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n"
    headers.each { |k, v| out << "#{k}: #{v}\r\n" }
    out << "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
    socket.write(out)
  end
end

class ClientTest < Minitest::Test
  LIVE_RESPONSE = <<~JSON
    {"model":"jev-1.13.0","answers":{"is_urgent":{"type":"noul","noul":0.96},
    "department":{"type":"choice","choice":"billing","confidence":0.88,
    "probabilities":{"sales":0.0,"billing":0.92,"technical":0.08}},
    "frustration":{"type":"score","score":1.22,"confidence":0.67,
    "legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},
    "probabilities":{"0":0.0,"1":0.78,"2":0.22}}},
    "usage":{"input_tokens":430,"output_tokens":73}}
  JSON

  def setup
    @slept = []
    @servers = []
  end

  def teardown
    @servers.each(&:shutdown)
  end

  def serve(&)
    server = StubServer.new(&)
    @servers << server
    server
  end

  def ok_server
    serve { |_req, _i| [200, {}, LIVE_RESPONSE] }
  end

  def config_for(server, **overrides)
    config = Jev::Configuration.new
    config.api_key = "test-key"
    config.base_url = server.url
    config.model = "jev-latest"
    config.max_retries = 2
    config.timeout = 2.0
    config.open_timeout = 2.0
    overrides.each { |k, v| config.public_send("#{k}=", v) }
    config
  end

  def client_for(server, **overrides)
    Jev::Client.new(config: config_for(server, **overrides), sleeper: ->(s) { @slept << s })
  end

  def questions
    {
      is_urgent: Jev.noul("Does this need an answer today?",
                          { "true" => "Needs an answer today", "false" => "Can wait" }),
      department: Jev.choice("Which team should handle it?",
                             { "billing" => "Invoices and payments", "technical" => "Bugs and outages" }),
      frustration: Jev.score("How upset is the customer?", ["Calm", "Frustrated", "Very angry"])
    }
  end

  def test_happy_path_returns_result_set
    server = ok_server
    results = client_for(server).call(state: "My invoice is wrong again!", questions: questions)

    assert_instance_of Jev::ResultSet, results
    assert_equal "jev-1.13.0", results.model
    assert_equal 503, results.usage.total
    assert_in_delta 0.96, results[:is_urgent].value
    assert results[:is_urgent].true?
    assert_equal "billing", results[:department].value
    assert_in_delta 0.92, results[:department].probability
    assert_equal 1, results[:frustration].level
    assert_equal "Frustrated", results[:frustration].label
    assert results.latency.positive?
    assert_empty @slept
  end

  def test_request_payload_is_exact
    server = ok_server
    client_for(server).call(state: "My invoice is wrong again!", questions: questions)

    request = server.requests.fetch(0)

    assert_equal "POST", request.http_method
    assert_equal "/v1/systemone", request.path
    assert_equal "Bearer test-key", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]
    assert_equal({
                   "state" => "My invoice is wrong again!",
                   "model" => "jev-latest",
                   "questions" => {
                     "is_urgent" => {
                       "type" => "noul",
                       "instructions" => "Does this need an answer today?",
                       "criteria" => { "true" => "Needs an answer today", "false" => "Can wait" }
                     },
                     "department" => {
                       "type" => "choice",
                       "instructions" => "Which team should handle it?",
                       "criteria" => { "billing" => "Invoices and payments",
                                       "technical" => "Bugs and outages" }
                     },
                     "frustration" => {
                       "type" => "score",
                       "instructions" => "How upset is the customer?",
                       "criteria" => ["Calm", "Frustrated", "Very angry"]
                     }
                   }
                 }, request.json)
  end

  def test_model_override_is_sent
    server = ok_server
    client_for(server).call(state: "hi", questions: questions, model: "jev-1.13.0")

    assert_equal "jev-1.13.0", server.requests.fetch(0).json["model"]
  end

  def test_connection_is_reused_across_calls
    server = ok_server
    client = client_for(server)
    2.times { client.call(state: "hi", questions: questions) }

    assert_equal 2, server.requests.size
    assert_equal 1, server.connections
  end

  def test_rate_limit_is_retried_then_succeeds
    server = serve do |_req, index|
      index.zero? ? [429, { "Retry-After" => "0.01" }, "{}"] : [200, {}, LIVE_RESPONSE]
    end

    results = client_for(server).call(state: "hi", questions: questions)

    assert_equal "jev-1.13.0", results.model
    assert_equal 2, server.requests.size
    assert_equal [0.01], @slept
  end

  def test_server_errors_exhaust_retries
    server = serve { |_req, _i| [503, {}, '{"error":{"message":"upstream down"}}'] }

    error = assert_raises(Jev::ServerError) do
      client_for(server).call(state: "hi", questions: questions)
    end

    assert_equal 503, error.status
    assert_includes error.message, "upstream down"
    assert_equal 3, server.requests.size
    assert_equal 2, @slept.size
  end

  def test_unauthorized_is_not_retried
    server = serve { |_req, _i| [401, {}, '{"error":"bad key"}'] }

    error = assert_raises(Jev::AuthenticationError) do
      client_for(server).call(state: "hi", questions: questions)
    end

    assert_equal 401, error.status
    assert_equal 1, server.requests.size
    assert_empty @slept
  end

  def test_read_timeout_raises_transport_error
    server = serve do |_req, _i|
      sleep 0.4
      [200, {}, LIVE_RESPONSE]
    end

    assert_raises(Jev::TransportError) do
      client_for(server, timeout: 0.1, max_retries: 0).call(state: "hi", questions: questions)
    end
  end

  def test_malformed_json_raises_invalid_response_error
    server = serve { |_req, _i| [200, {}, "not json at all"] }

    assert_raises(Jev::InvalidResponseError) do
      client_for(server).call(state: "hi", questions: questions)
    end
  end

  def test_missing_api_key_raises_configuration_error
    server = ok_server

    assert_raises(Jev::ConfigurationError) do
      client_for(server, api_key: nil).call(state: "hi", questions: questions)
    end

    assert_empty server.requests
  end

  def test_logger_receives_one_line_per_attempt_without_secrets
    lines = []
    logger = Object.new
    logger.define_singleton_method(:debug) { |msg = nil, &blk| lines << (msg || blk.call) }
    server = serve { |_req, index| index.zero? ? [429, {}, "{}"] : [200, {}, LIVE_RESPONSE] }

    client_for(server, logger: logger).call(state: "hi", questions: questions)

    assert_equal 2, lines.size
    assert_includes lines.first, "status=429"
    assert_includes lines.last, "attempt=2"
    refute(lines.any? { |l| l.include?("test-key") })
  end
end
