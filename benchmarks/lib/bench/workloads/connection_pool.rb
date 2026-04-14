# frozen_string_literal: true

module Bench
  module Workloads
    class ConnectionPool
      POOL_SIZE = 5
      HOLD_DURATION = 0.001  # 1ms — simulated query/IO time

      class FiberPool
        def initialize(size)
          @resources = Array.new(size) { |i| :"resource_#{i}" }
          @waiters = []
        end

        def checkout
          until @resources.any?
            fiber = Fiber.current
            @waiters << fiber

            begin
              Fiber.scheduler.block(self, nil)
            ensure
              @waiters.delete(fiber)
            end
          end

          @resources.shift
        end

        def checkin(resource)
          @resources << resource

          if (fiber = @waiters.shift)
            Fiber.scheduler.unblock(self, fiber)
          end
        end
      end

      def call(_scheduler, options)
        worker_count = Integer(options.fetch(:concurrency, 50))
        iterations = Integer(options.fetch(:iterations, 100))
        pool = FiberPool.new(POOL_SIZE)
        samples = Array.new(worker_count, 0.0)
        started_at = Bench.monotonic_time

        worker_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time

            iterations.times do
              resource = pool.checkout
              sleep(HOLD_DURATION)
              pool.checkin(resource)
            end

            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        total_checkouts = worker_count * iterations

        {
          "checkouts_per_second" => total_checkouts / (finished_at - started_at),
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
