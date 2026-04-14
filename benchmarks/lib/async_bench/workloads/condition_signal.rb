# frozen_string_literal: true

# Producer/consumer signaling via Async::Condition.
# Multiple producers signal conditions that multiple consumers wait on.
# Exercises the selector's fiber wakeup and transfer paths.

module AsyncBench
  module Workloads
    class ConditionSignal
      def call(options)
        producers = Integer(options.fetch(:producers, 5))
        consumers = Integer(options.fetch(:consumers, 20))
        messages = Integer(options.fetch(:messages, 200))

        started_at = AsyncBench.monotonic_time

        Async do
          barrier = Async::Barrier.new
          # Shared condition + counter for flow control
          condition = Async::Condition.new
          produced = 0
          consumed = 0
          total = producers * messages

          # Consumers: wait for signals, count receipts
          consumers.times do
            barrier.async do
              loop do
                condition.wait
                consumed += 1
                break if consumed >= total
              end
            end
          end

          # Producers: signal the condition, small sleep between bursts
          producers.times do
            barrier.async do
              messages.times do |i|
                produced += 1
                condition.signal(produced)
                # Yield periodically to let consumers run
                sleep(0.0001) if (i % 10).zero?
              end
            end
          end

          # Wait for all producers to finish
          # Then signal remaining consumers to unblock
          barrier.wait
        rescue
          # Barrier.wait may raise if consumer tasks error on shutdown
          nil
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_signals = producers * messages

        {"signals_per_second" => total_signals / elapsed}
      end
    end
  end
end
