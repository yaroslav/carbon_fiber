# frozen_string_literal: true

# Fan-out/gather using Async::Barrier with Async::Semaphore for concurrency control.
# Each coordinator fans out tasks, each doing a short sleep, then gathers results.

module AsyncBench
  module Workloads
    class BarrierFanout
      MIN_SLEEP = 0.001
      MAX_SLEEP = 0.005

      def call(options)
        coordinators = Integer(options.fetch(:coordinators, 10))
        fan_width = Integer(options.fetch(:fan_width, 10))
        iterations = Integer(options.fetch(:iterations, 100))
        sleep_range = MAX_SLEEP - MIN_SLEEP

        started_at = AsyncBench.monotonic_time

        Async do |task|
          barrier = Async::Barrier.new
          semaphore = Async::Semaphore.new(coordinators)

          coordinators.times do |c|
            barrier.async(parent: semaphore) do
              iterations.times do |iter|
                inner = Async::Barrier.new
                results = Array.new(fan_width)

                fan_width.times do |i|
                  inner.async do
                    latency = MIN_SLEEP + (sleep_range * ((iter * fan_width + i) % 7) / 6.0)
                    sleep(latency)
                    results[i] = i
                  end
                end

                inner.wait
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_cycles = coordinators * iterations

        {"cycles_per_second" => total_cycles / elapsed}
      end
    end
  end
end
