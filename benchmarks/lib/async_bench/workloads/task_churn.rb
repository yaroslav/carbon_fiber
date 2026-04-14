# frozen_string_literal: true

# Measures raw Async task creation and completion throughput.
# Each iteration spawns a batch of tasks that yield once and finish.

module AsyncBench
  module Workloads
    class TaskChurn
      def call(options)
        batch_size = Integer(options.fetch(:batch_size, 100))
        iterations = Integer(options.fetch(:iterations, 200))

        started_at = AsyncBench.monotonic_time

        Async do |task|
          iterations.times do
            barrier = Async::Barrier.new
            batch_size.times do
              barrier.async do
                # Minimal work: just yield to exercise task lifecycle
                task.yield
              end
            end
            barrier.wait
          end
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_tasks = batch_size * iterations

        {"tasks_per_second" => total_tasks / elapsed}
      end
    end
  end
end
