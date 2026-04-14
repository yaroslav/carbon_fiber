# frozen_string_literal: true

# TCP echo throughput using Async's IO facilities.
# Multiple clients connect to a local TCP server and exchange payloads.

require "socket"

module AsyncBench
  module Workloads
    class TcpThroughput
      def call(options)
        clients = Integer(options.fetch(:clients, 10))
        iterations = Integer(options.fetch(:iterations, 200))
        payload_size = Integer(options.fetch(:payload, 512))
        payload = "x" * payload_size

        started_at = AsyncBench.monotonic_time

        Async do |task|
          server = TCPServer.new("127.0.0.1", 0)
          port = server.local_address.ip_port

          barrier = Async::Barrier.new

          # Server: accept connections, echo back
          barrier.async do
            clients.times do
              conn = server.accept
              barrier.async do
                iterations.times do
                  data = conn.readpartial(payload_size)
                  conn.write(data)
                end
              rescue EOFError, IOError
                # Client closed
              ensure
                begin
                  conn.close
                rescue
                  nil
                end
              end
            end
          ensure
            begin
              server.close
            rescue
              nil
            end
          end

          # Clients
          clients.times do
            barrier.async do
              sock = TCPSocket.new("127.0.0.1", port)
              iterations.times do
                sock.write(payload)
                sock.readpartial(payload_size)
              end
            ensure
              begin
                sock&.close
              rescue
                nil
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_ops = clients * iterations

        {"operations_per_second" => total_ops / elapsed}
      end
    end
  end
end
