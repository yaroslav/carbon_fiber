# frozen_string_literal: true

# Semaphore-based connection pool contention using Async primitives.
# N workers compete for M pooled slots, simulating ActiveRecord-style pool checkout.

module AsyncBench
  module Workloads
    class ConnectionPool
      POOL_SIZE = 5
      HOLD_DURATION = 0.001 # 1ms — simulated query/IO time

      def call(options)
        worker_count = Integer(options.fetch(:concurrency, 50))
        iterations = Integer(options.fetch(:iterations, 100))

        started_at = AsyncBench.monotonic_time

        Async do
          semaphore = Async::Semaphore.new(POOL_SIZE)
          barrier = Async::Barrier.new

          worker_count.times do
            barrier.async do
              iterations.times do
                semaphore.acquire do
                  sleep(HOLD_DURATION)
                end
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_checkouts = worker_count * iterations

        {"checkouts_per_second" => total_checkouts / elapsed}
      end
    end
  end
end
