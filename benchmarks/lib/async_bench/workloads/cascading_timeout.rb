# frozen_string_literal: true

# Timeout handling under load: 70% fast tasks complete within deadline,
# 30% slow tasks get killed by timeout. Tests Async's timeout machinery.

module AsyncBench
  module Workloads
    class CascadingTimeout
      TIMEOUT_DURATION = 0.010 # 10ms deadline
      FAST_WORK = 0.002        # 2ms — completes within deadline
      SLOW_WORK = 0.050        # 50ms — exceeds deadline, gets killed

      def call(options)
        worker_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 200))

        started_at = AsyncBench.monotonic_time

        Async do
          barrier = Async::Barrier.new

          worker_count.times do |index|
            barrier.async do
              iterations.times do |iter|
                slow = ((iter * 7 + index * 3) % 10) < 3

                begin
                  Async::Task.current.with_timeout(TIMEOUT_DURATION) do
                    sleep(slow ? SLOW_WORK : FAST_WORK)
                  end
                rescue Async::TimeoutError
                  # Expected for slow tasks
                end
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_ops = worker_count * iterations

        {"operations_per_second" => total_ops / elapsed}
      end
    end
  end
end
