# frozen_string_literal: true

require "socket"
require_relative "socket_helpers"

module Bench
  module Workloads
    class HttpServer
      include SocketHelpers

      RESPONSE_BODY = "Hello, World!"
      RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: #{RESPONSE_BODY.bytesize}\r\nConnection: keep-alive\r\n\r\n#{RESPONSE_BODY}"
      REQUEST = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"

      def call(_scheduler, options)
        client_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 200))
        samples = Array.new(client_count, 0.0)
        server_sockets = []
        client_sockets = []

        server = TCPServer.new("127.0.0.1", 0)
        port = server.local_address.ip_port
        started_at = Bench.monotonic_time

        Fiber.schedule do
          client_count.times do
            conn = server.accept
            server_sockets << conn

            Fiber.schedule do
              handle_connection(conn, iterations)
            ensure
              close_socket(conn)
            end
          end

          server.close
        end

        client_count.times do |index|
          Fiber.schedule do
            sock = TCPSocket.new("127.0.0.1", port)
            client_sockets << sock
            fiber_started_at = Bench.monotonic_time

            begin
              iterations.times do
                sock.write(REQUEST)
                read_http_response(sock)
              end
            ensure
              samples[index] = Bench.monotonic_time - fiber_started_at
              close_socket(sock)
            end
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        total_requests = client_count * iterations

        {
          "requests_per_second" => total_requests / (finished_at - started_at),
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      ensure
        server_sockets.each { |s| close_socket(s) }
        client_sockets.each { |s| close_socket(s) }
        close_socket(server) if server && !server.closed?
      end

      private

      def handle_connection(conn, iterations)
        iterations.times do
          request = +""
          loop do
            request << conn.readpartial(4096)
            break if request.include?("\r\n\r\n")
          end

          conn.write(RESPONSE)
        end
      end

      def read_http_response(sock)
        headers = +""
        loop do
          headers << sock.readpartial(4096)
          break if headers.include?("\r\n\r\n")
        end

        header_end = headers.index("\r\n\r\n") + 4
        body_received = headers.bytesize - header_end

        if (match = headers.match(/Content-Length:\s*(\d+)/i))
          content_length = match[1].to_i
          remaining = content_length - body_received
          while remaining > 0
            chunk = sock.readpartial(remaining)
            remaining -= chunk.bytesize
          end
        end
      end
    end
  end
end
