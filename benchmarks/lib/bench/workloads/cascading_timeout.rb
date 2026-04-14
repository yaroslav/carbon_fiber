# frozen_string_literal: true

require "timeout"

module Bench
  module Workloads
    class CascadingTimeout
      TIMEOUT_DURATION = 0.010   # 10ms deadline
      FAST_WORK = 0.002          # 2ms — completes within deadline
      SLOW_WORK = 0.050          # 50ms — exceeds deadline, gets killed

      def call(_scheduler, options)
        worker_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 200))
        samples = Array.new(worker_count, 0.0)
        completed_count = 0
        timed_out_count = 0
        count_mutex = Mutex.new
        started_at = Bench.monotonic_time

        worker_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time
            local_completed = 0
            local_timed_out = 0

            iterations.times do |iter|
              slow = ((iter * 7 + index * 3) % 10) < 3

              begin
                Fiber.scheduler.timeout_after(TIMEOUT_DURATION, Timeout::Error, "benchmark timeout") do
                  sleep(slow ? SLOW_WORK : FAST_WORK)
                  local_completed += 1
                end
              rescue Timeout::Error
                local_timed_out += 1
              end
            end

            count_mutex.synchronize do
              completed_count += local_completed
              timed_out_count += local_timed_out
            end
            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        elapsed = finished_at - started_at
        total_ops = worker_count * iterations

        {
          "operations_per_second" => total_ops / elapsed,
          "completed" => completed_count,
          "timed_out" => timed_out_count,
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
