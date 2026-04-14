# frozen_string_literal: true

require "socket"

module Bench
  module Workloads
    class WebsocketIdle
      PING_INTERVAL = 0.010  # 10ms between pings
      PING_PAYLOAD = "ping"
      PONG_PAYLOAD = "pong"

      def call(_scheduler, options)
        conn_count = Integer(options.fetch(:concurrency, 50))
        iterations = Integer(options.fetch(:iterations, 100))
        samples = Array.new(conn_count, 0.0)
        sockets = []
        started_at = Bench.monotonic_time

        server = TCPServer.new("127.0.0.1", 0)
        sockets << server
        port = server.local_address.ip_port

        Fiber.schedule do
          conn_count.times do
            conn = server.accept
            sockets << conn
            Fiber.schedule do
              loop do
                conn.readpartial(64)
                conn.write(PONG_PAYLOAD)
              rescue IOError
                break
              end
            ensure
              begin
                conn.close
              rescue
                nil
              end
            end
          end
          begin
            server.close
          rescue
            nil
          end
        end

        conn_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time
            sock = TCPSocket.new("127.0.0.1", port)
            sockets << sock

            begin
              iterations.times do
                sleep(PING_INTERVAL)
                sock.write(PING_PAYLOAD)
                sock.readpartial(64)
              end
            ensure
              begin
                sock.close
              rescue
                nil
              end
            end

            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        elapsed = finished_at - started_at
        total_pings = conn_count * iterations

        {
          "pings_per_second" => total_pings / elapsed,
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
