# frozen_string_literal: true

module Bench
  module Workloads
    class FanOutGather
      FANOUT_WIDTH = 5
      MIN_LATENCY = 0.001  # 1ms
      MAX_LATENCY = 0.005  # 5ms

      class Barrier
        def initialize
          @pending = 0
          @waiter = nil
        end

        def async
          @pending += 1

          Fiber.schedule do
            yield
          ensure
            @pending -= 1
            if @pending.zero? && @waiter
              Fiber.scheduler.unblock(self, @waiter)
              @waiter = nil
            end
          end
        end

        def wait
          return if @pending.zero?

          @waiter = Fiber.current
          Fiber.scheduler.block(self, nil)
        end
      end

      def call(_scheduler, options)
        coordinator_count = Integer(options.fetch(:concurrency, 10))
        iterations = Integer(options.fetch(:iterations, 100))
        samples = Array.new(coordinator_count, 0.0)
        latency_range = MAX_LATENCY - MIN_LATENCY
        started_at = Bench.monotonic_time

        coordinator_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time

            iterations.times do |iter|
              barrier = Barrier.new
              results = Array.new(FANOUT_WIDTH)

              FANOUT_WIDTH.times do |i|
                barrier.async do
                  latency = MIN_LATENCY + (latency_range * ((iter * FANOUT_WIDTH + i) % 7) / 6.0)
                  sleep(latency)
                  results[i] = i
                end
              end

              barrier.wait
            end

            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        total_operations = coordinator_count * iterations

        {
          "gather_cycles_per_second" => total_operations / (finished_at - started_at),
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
