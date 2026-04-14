# frozen_string_literal: true

# Stress-tests timer management: many concurrent fibers sleeping with varied durations.
# Exercises the selector's timer heap under high contention.

module AsyncBench
  module Workloads
    class SleepStorm
      def call(options)
        fibers = Integer(options.fetch(:fibers, 200))
        iterations = Integer(options.fetch(:iterations, 50))

        started_at = AsyncBench.monotonic_time

        Async do
          barrier = Async::Barrier.new

          fibers.times do |f|
            barrier.async do
              iterations.times do |i|
                # Varied sleep durations: 0.5ms to 5ms
                duration = 0.0005 + (0.0045 * ((f * iterations + i) % 11) / 10.0)
                sleep(duration)
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_sleeps = fibers * iterations

        {"sleeps_per_second" => total_sleeps / elapsed}
      end
    end
  end
end
