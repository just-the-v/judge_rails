# frozen_string_literal: true

require "json"
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
