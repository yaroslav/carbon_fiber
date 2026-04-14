# frozen_string_literal: true

require "socket"

module Bench
  module Workloads
    class DnsFanout
      HOSTNAMES = %w[
        localhost
        localhost
        localhost
        localhost
        localhost
      ].freeze

      def call(_scheduler, options)
        worker_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 50))
        samples = Array.new(worker_count, 0.0)
        total_resolutions = 0
        count_mutex = Mutex.new
        started_at = Bench.monotonic_time

        worker_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time
            local_count = 0

            iterations.times do
              HOSTNAMES.each do |hostname|
                Addrinfo.getaddrinfo(hostname, nil)
                local_count += 1
              end
            end

            count_mutex.synchronize { total_resolutions += local_count }
            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        elapsed = finished_at - started_at

        {
          "resolutions_per_second" => total_resolutions / elapsed,
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      end
    end
  end
end
