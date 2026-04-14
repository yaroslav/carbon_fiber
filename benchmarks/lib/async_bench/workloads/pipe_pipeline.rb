# frozen_string_literal: true

# Multi-stage pipeline using Async::Queue. A producer pushes messages through
# a chain of stages, each backed by a queue. Exercises queue signaling and
# task scheduling under sustained throughput.

module AsyncBench
  module Workloads
    class PipePipeline
      def call(options)
        stages = Integer(options.fetch(:stages, 5))
        messages = Integer(options.fetch(:messages, 500))
        payload = Integer(options.fetch(:payload, 512))
        data = "x" * payload

        started_at = AsyncBench.monotonic_time

        Async do
          # Build a chain of queues: producer → stage1 → stage2 → ... → sink
          queues = Array.new(stages + 1) { Async::Queue.new }

          barrier = Async::Barrier.new

          # Stage workers: read from input queue, process, write to output queue
          stages.times do |s|
            barrier.async do
              input = queues[s]
              output = queues[s + 1]
              while (msg = input.dequeue)
                output.push(msg)
              end
              output.close
            end
          end

          # Producer: push messages into the first queue
          barrier.async do
            messages.times { queues[0].push(data) }
            queues[0].close
          end

          # Consumer: drain the last queue
          received = 0
          barrier.async do
            while queues[stages].dequeue
              received += 1
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at

        {"messages_per_second" => messages / elapsed}
      end
    end
  end
end
