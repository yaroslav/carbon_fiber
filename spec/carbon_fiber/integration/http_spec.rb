# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "socket"
require "uri"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  # Minimal thread-based HTTP/1.1 server — same loopback pattern as the
  # http_client_api and http_client_download benchmarks.
  def start_loopback_server(body:, keep_alive: false)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        client = begin
          server.accept
        rescue
          break
        end
        Thread.new do
          Thread.current.report_on_exception = false
          buf = +""
          buf << client.readpartial(4096) until buf.include?("\r\n\r\n")
          headers = +"HTTP/1.1 200 OK\r\n"
          headers << "Content-Length: #{body.bytesize}\r\n"
          headers << (keep_alive ? "Connection: keep-alive\r\n" : "Connection: close\r\n")
          headers << "\r\n"
          client.write(headers + body)
          client.close
        end
      end
    ensure
      server.close
    end

    [port, thread]
  end

  describe "making HTTP requests with Net::HTTP" do
    it "retrieves a response body over a single connection" do
      port, server_thread = start_loopback_server(body: "hello")
      result = nil

      Fiber.schedule do
        result = Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
      end

      scheduler.run
      server_thread.join(1)
      expect(result).to eq("hello")
    end

    it "runs multiple concurrent GET requests" do
      port, server_thread = start_loopback_server(body: "ok")
      results = []

      3.times do
        Fiber.schedule do
          results << Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
        end
      end

      scheduler.run
      server_thread.join(1)
      expect(results).to contain_exactly("ok", "ok", "ok")
    end

    it "downloads a large response body" do
      body = "x" * (256 * 1024)
      port, server_thread = start_loopback_server(body: body)
      result = nil

      Fiber.schedule do
        result = Net::HTTP.get(URI("http://127.0.0.1:#{port}/"))
      end

      scheduler.run
      server_thread.join(1)
      expect(result.bytesize).to eq(256 * 1024)
    end
  end
end
