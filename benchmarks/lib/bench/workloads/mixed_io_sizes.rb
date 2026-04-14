# frozen_string_literal: true

require "socket"

module Bench
  module Workloads
    class MixedIoSizes
      SMALL_PAYLOAD = 64
      LARGE_PAYLOAD = 256 * 1024  # 256KB
      LARGE_RATIO = 3             # 1 in 3 clients is large

      def call(_scheduler, options)
        client_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 50))
        small_data = "x" * SMALL_PAYLOAD
        large_data = "X" * LARGE_PAYLOAD
        samples = Array.new(client_count, 0.0)
        total_bytes = 0
        bytes_mutex = Mutex.new
        sockets = []
        started_at = Bench.monotonic_time

        server = TCPServer.new("127.0.0.1", 0)
        sockets << server
        port = server.local_address.ip_port

        Fiber.schedule do
          client_count.times do
            conn = server.accept
            sockets << conn
            Fiber.schedule do
              loop do
                data = conn.readpartial(512 * 1024)
                conn.write(data)
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

        client_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time
            large = (index % LARGE_RATIO).zero?
            payload = large ? large_data : small_data
            payload_size = payload.bytesize
            local_bytes = 0

            sock = TCPSocket.new("127.0.0.1", port)
            sockets << sock
            begin
              iterations.times do
                sock.write(payload)
                remaining = payload_size
                while remaining > 0
                  chunk = sock.readpartial([remaining, 512 * 1024].min)
                  remaining -= chunk.bytesize
                  local_bytes += chunk.bytesize
                end
              end
            ensure
              begin
                sock.close
              rescue
                nil
              end
            end

            bytes_mutex.synchronize { total_bytes += local_bytes }
            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        elapsed = finished_at - started_at

        {
          "bytes_per_second" => total_bytes / elapsed,
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
