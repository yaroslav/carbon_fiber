# frozen_string_literal: true

require "socket"
require_relative "socket_helpers"

module Bench
  module Workloads
    class TcpEcho
      include SocketHelpers

      def call(_scheduler, options)
        client_count = Integer(options.fetch(:concurrency, 30))
        iterations = Integer(options.fetch(:iterations, 200))
        payload_bytes = Integer(options.fetch(:payload_bytes, 512))
        payload = "x" * payload_bytes
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
              iterations.times do
                message = read_exact(conn, payload_bytes)
                write_all(conn, message)
              end
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
                write_all(sock, payload)
                read_exact(sock, payload_bytes)
              end
            ensure
              samples[index] = Bench.monotonic_time - fiber_started_at
              close_socket(sock)
            end
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        operations = client_count * iterations
        bytes_transferred = operations * payload_bytes * 2

        {
          "operations_per_second" => operations / (finished_at - started_at),
          "bytes_per_second" => bytes_transferred / (finished_at - started_at),
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      ensure
        server_sockets.each { |s| close_socket(s) }
        client_sockets.each { |s| close_socket(s) }
        close_socket(server) if server && !server.closed?
      end
    end
  end
end
