# frozen_string_literal: true

require "digest"
require "json"
require "socket"

class FakeJev
  PATH = "/v1/systemone"

  Failure = Struct.new(:status, :retry_after, :body, keyword_init: true)

  class << self
    def start(...)
      new(...).tap(&:start)
    end

    def run(...)
      server = start(...)
      begin
        yield server
      ensure
        server.stop
      end
    end
  end

  attr_reader :host, :port

  def initialize(host: "127.0.0.1", model: "jev-1.13.0", envelope: nil)
    @host = host
    @model = model
    @envelope = envelope
    @headers = []
    @mutex = Mutex.new
    @requests = []
    @answers = {}
    @scoped_answers = []
    @failures = []
    @always_fail = nil
    @latency = 0.0
    @connections = []
    @running = false
  end

  def start
    @socket = TCPServer.new(@host, 0)
    @port = @socket.addr[1]
    @running = true
    @acceptor = Thread.new { accept_loop }
    self
  end

  def stop
    return unless @running

    @running = false
    @socket.close unless @socket.closed?
    @acceptor&.join(5)
    @mutex.synchronize { @connections.dup }.each { |t| t.join(5) }
    @mutex.synchronize { @connections.clear }
    nil
  end

  def url
    "http://#{@host}:#{@port}#{PATH}"
  end

  def latency=(seconds)
    @mutex.synchronize { @latency = seconds.to_f }
  end

  def answer(name, payload)
    @mutex.synchronize { @answers[name.to_s] = payload }
    self
  end

  def answer_for(state_substring, name, payload)
    @mutex.synchronize { @scoped_answers << [state_substring.to_s, name.to_s, payload] }
    self
  end

  def clear_answers!
    @mutex.synchronize do
      @answers.clear
      @scoped_answers.clear
    end
    self
  end

  def fail_next(count = 1, status: 500, retry_after: nil, body: nil)
    @mutex.synchronize do
      count.times { @failures << Failure.new(status: status, retry_after: retry_after, body: body) }
    end
    self
  end

  def always_fail(status: 500, retry_after: nil, body: nil)
    @mutex.synchronize { @always_fail = Failure.new(status: status, retry_after: retry_after, body: body) }
    self
  end

  def clear_failures!
    @mutex.synchronize do
      @failures.clear
      @always_fail = nil
    end
    self
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def last_request
    @mutex.synchronize { @requests.last }
  end

  def last_headers
    @mutex.synchronize { @headers.last }
  end

  def request_count
    @mutex.synchronize { @requests.size }
  end

  def reset!
    @mutex.synchronize do
      @requests.clear
      @headers.clear
      @answers.clear
      @scoped_answers.clear
      @failures.clear
      @always_fail = nil
      @latency = 0.0
    end
    self
  end

  private

  def accept_loop
    while @running
      begin
        client = @socket.accept
      rescue IOError, Errno::EBADF, Errno::EINVAL
        break
      end

      thread = Thread.new(client) { |sock| serve(sock) }
      @mutex.synchronize do
        @connections.select!(&:alive?)
        @connections << thread
      end
    end
  end

  def serve(sock)
    request = read_request(sock)
    return unless request

    status, headers, body = dispatch(request)
    delay = @mutex.synchronize { @latency }
    sleep(delay) if delay.positive?
    write_response(sock, status, headers, body)
  rescue Errno::EPIPE, Errno::ECONNRESET, IOError
    nil
  ensure
    begin
      sock.close
    rescue IOError
      nil
    end
  end

  def read_request(sock)
    request_line = sock.gets
    return nil if request_line.nil?

    method, path, = request_line.split
    headers = {}
    while (line = sock.gets)
      line = line.chomp
      break if line.empty?

      key, value = line.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip
    end
    length = headers["content-length"].to_i
    body = length.positive? ? sock.read(length) : ""
    { method: method, path: path, headers: headers, body: body }
  end

  def dispatch(request)
    return error(405, "invalid_request_error", "only POST is supported") unless request[:method] == "POST"
    unless authorized?(request[:headers]["authorization"])
      return error(401, "authentication_error", "missing or empty bearer token")
    end

    payload = parse_body(request[:body])
    return error(400, "invalid_request_error", "malformed JSON body") unless payload

    @mutex.synchronize do
      @requests << payload
      @headers << request[:headers].merge("path" => request[:path])
    end

    failure = next_failure
    return failure_response(failure) if failure

    [200, {}, JSON.generate(envelope(build_response(payload)))]
  end

  def authorized?(header)
    return false if header.nil?

    match = header.match(/\ABearer\s+(\S+)\z/i)
    !match.nil?
  end

  def parse_body(body)
    parsed = JSON.parse(body)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def next_failure
    @mutex.synchronize { @always_fail || @failures.shift }
  end

  def failure_response(failure)
    headers = failure.retry_after ? { "Retry-After" => failure.retry_after.to_s } : {}
    body = failure.body || JSON.generate(error_body(error_type(failure.status), "injected failure"))
    [failure.status, headers, body]
  end

  def envelope(response)
    return response unless @envelope == :cloudflare

    { "result" => response, "success" => true, "errors" => [], "messages" => [] }
  end

  def error_body(type, message)
    if @envelope == :cloudflare
      { "result" => nil, "success" => false, "errors" => [{ "code" => 5012, "message" => message }],
        "messages" => [] }
    else
      { "error" => { "type" => type, "message" => message } }
    end
  end

  def error_type(status)
    case status
    when 401 then "authentication_error"
    when 429 then "rate_limit_error"
    when 400..499 then "invalid_request_error"
    else "server_error"
    end
  end

  def error(status, type, message)
    [status, {}, JSON.generate(error_body(type, message))]
  end

  def build_response(payload)
    state = payload["state"].to_s
    questions = payload["questions"].is_a?(Hash) ? payload["questions"] : {}

    answers = questions.to_h { |name, question| [name, answer_for_question(state, name, question)] }

    {
      "model" => @model,
      "answers" => answers,
      "usage" => usage_for(state, questions)
    }
  end

  def answer_for_question(state, name, question)
    override = overridden_answer(state, name)
    return override if override

    seed = "#{question["instructions"]}\u0000#{state}"
    case question["type"]
    when "choice" then choice_answer(seed, question["criteria"])
    when "score" then score_answer(seed, question["criteria"])
    else noul_answer(seed)
    end
  end

  def overridden_answer(state, name)
    @mutex.synchronize do
      scoped = @scoped_answers.reverse.find { |sub, qname, _| qname == name && state.include?(sub) }
      scoped ? scoped[2] : @answers[name]
    end
  end

  def noul_answer(seed)
    { "type" => "noul", "noul" => unit(seed, "noul").round(2) }
  end

  def choice_answer(seed, criteria)
    options = option_names(criteria)
    probabilities = distribution(seed, options)
    winner = probabilities.max_by { |_, p| p }.first
    {
      "type" => "choice",
      "choice" => winner,
      "confidence" => confidence(seed),
      "probabilities" => probabilities
    }
  end

  def score_answer(seed, criteria)
    levels = criteria.is_a?(Array) && !criteria.empty? ? criteria.map(&:to_s) : %w[low high]
    keys = levels.each_index.map(&:to_s)
    probabilities = distribution(seed, keys)
    score = probabilities.sum { |key, p| key.to_i * p }
    {
      "type" => "score",
      "score" => score.round(2),
      "confidence" => confidence(seed),
      "legend" => keys.zip(levels).to_h,
      "probabilities" => probabilities
    }
  end

  def option_names(criteria)
    names = case criteria
            when Hash then criteria.keys
            when Array then criteria
            end
    names = %w[yes no] if names.nil? || names.empty?
    names.map(&:to_s)
  end

  def distribution(seed, keys)
    weights = keys.to_h { |key| [key, 0.05 + unit(seed, "w:#{key}")] }
    total = weights.values.sum
    winner = weights.max_by { |key, weight| [weight, key] }.first
    probabilities = weights.to_h { |key, weight| [key, (weight / total).round(2)] }
    remainder = probabilities.reject { |key, _| key == winner }.values.sum
    probabilities[winner] = (1.0 - remainder).round(2)
    probabilities
  end

  def confidence(seed)
    (0.5 + (unit(seed, "confidence") * 0.5)).round(2)
  end

  def usage_for(state, questions)
    seed = "#{state}\u0000#{questions.keys.sort.join(",")}"
    {
      "input_tokens" => 100 + (digest_int(seed, "in") % 900),
      "output_tokens" => 20 + (digest_int(seed, "out") % 180)
    }
  end

  def unit(seed, salt)
    (digest_int(seed, salt) % 1_000_001) / 1_000_000.0
  end

  def digest_int(seed, salt)
    Digest::SHA256.hexdigest("#{salt}\u0000#{seed}")[0, 15].to_i(16)
  end

  def write_response(sock, status, headers, body)
    all = {
      "Content-Type" => "application/json",
      "Content-Length" => body.bytesize.to_s,
      "Connection" => "close"
    }.merge(headers)
    lines = all.map { |k, v| "#{k}: #{v}\r\n" }.join
    sock.write("HTTP/1.1 #{status} #{reason(status)}\r\n#{lines}\r\n#{body}")
  end

  def reason(status)
    {
      200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 405 => "Method Not Allowed",
      429 => "Too Many Requests", 500 => "Internal Server Error", 503 => "Service Unavailable"
    }.fetch(status, "Error")
  end
end
