# frozen_string_literal: true

# Producer/consumer signaling via Async::Queue.
# Multiple producers push to a shared queue that multiple consumers pop.
# Exercises the selector's fiber wakeup and transfer paths under contention.

module AsyncBench
  module Workloads
    class ConditionSignal
      def call(options)
        producers = Integer(options.fetch(:producers, 5))
        consumers = Integer(options.fetch(:consumers, 20))
        messages = Integer(options.fetch(:messages, 200))

        started_at = AsyncBench.monotonic_time

        Async do
          consumer_barrier = Async::Barrier.new
          producer_barrier = Async::Barrier.new
          queue = Async::Queue.new
          total = producers * messages

          consumers.times do
            consumer_barrier.async do
              loop do
                item = queue.dequeue
                break if item == :drain
              end
            end
          end

          producers.times do
            producer_barrier.async do
              messages.times do |i|
                queue.enqueue(i)
                # Yield periodically to let consumers run.
                sleep(0.0001) if (i % 10).zero?
              end
            end
          end

          producer_barrier.wait
          # Send one drain marker per consumer so every consumer's pop()
          # observes a sentinel and exits its loop. Buffered queue, so
          # markers never get lost even if a consumer is mid-yield.
          consumers.times { queue.enqueue(:drain) }
          consumer_barrier.wait
          total
        rescue
          # Barrier.wait may raise if consumer tasks error on shutdown.
          nil
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_signals = producers * messages

        {"signals_per_second" => total_signals / elapsed}
      end
    end
  end
end
