# frozen_string_literal: true

require "socket"

module Bench
  module Workloads
    class DbQueryMix
      POOL_SIZE = 5
      QUERIES_MIN = 3
      QUERIES_MAX = 5
      QUERY_LATENCY_MIN = 0.001  # 1ms
      QUERY_LATENCY_MAX = 0.005  # 5ms

      class ConnPool
        def initialize(size)
          @conns = Array.new(size) { |i| Socket.pair(:UNIX, :STREAM, 0) }
          @available = @conns.dup
          @waiters = []
        end

        def checkout
          until @available.any?
            fiber = Fiber.current
            @waiters << fiber
            begin
              Fiber.scheduler.block(self, nil)
            ensure
              @waiters.delete(fiber)
            end
          end
          @available.shift
        end

        def checkin(conn)
          @available << conn
          if (fiber = @waiters.shift)
            Fiber.scheduler.unblock(self, fiber)
          end
        end

        def close_all
          @conns.each do |client, server|
            begin
              client.close
            rescue
              nil
            end
            begin
              server.close
            rescue
              nil
            end
          end
        end
      end

      def call(_scheduler, options)
        worker_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 100))
        pool = ConnPool.new(POOL_SIZE)
        samples = Array.new(worker_count, 0.0)
        total_queries = 0
        query_mutex = Mutex.new
        latency_range = QUERY_LATENCY_MAX - QUERY_LATENCY_MIN
        started_at = Bench.monotonic_time

        worker_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time
            local_queries = 0

            iterations.times do |iter|
              client, server = pool.checkout
              num_queries = QUERIES_MIN + ((iter + index) % (QUERIES_MAX - QUERIES_MIN + 1))

              num_queries.times do |q|
                query = "SELECT #{q} FROM t#{iter}"
                client.write(query)
                server.readpartial(4096)
                latency = QUERY_LATENCY_MIN + (latency_range * ((iter * num_queries + q) % 7) / 6.0)
                sleep(latency)
                local_queries += 1
              end

              pool.checkin([client, server])
            end

            query_mutex.synchronize { total_queries += local_queries }
            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        elapsed = finished_at - started_at

        pool.close_all

        {
          "queries_per_second" => total_queries / elapsed,
          "requests_per_second" => (worker_count * iterations) / elapsed,
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
