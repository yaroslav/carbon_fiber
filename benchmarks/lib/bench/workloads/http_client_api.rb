# frozen_string_literal: true

require "net/http"
require_relative "http_client_support"

module Bench
  module Workloads
    class HttpClientApi
      include HttpClientSupport

      RESPONSE_BODY = %({"ok":true,"value":12345})
      REQUEST_PATH = "/api"

      def call(_scheduler, options)
        client_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 200))
        max_wait_ms = Float(options.fetch(:max_wait_ms, 10_000.0))
        samples = Array.new(client_count, 0.0)
        server = HttpClientSupport::LoopbackServer.new(
          response_body: RESPONSE_BODY,
          content_type: "application/json"
        )
        started_at = Bench.monotonic_time
        benchmark_thread = Thread.current

        client_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time

            Net::HTTP.start("127.0.0.1", server.port, nil, nil) do |http|
              iterations.times do
                request = Net::HTTP::Get.new(REQUEST_PATH)
                response = http.request(request)
                raise "unexpected status #{response.code}" unless response.code == "200"
                raise "unexpected body size" unless response.body&.bytesize == RESPONSE_BODY.bytesize
              end
            end

            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        watchdog = Thread.new do
          Thread.current.report_on_exception = false
          sleep(max_wait_ms / 1000.0)
          benchmark_thread.raise(RuntimeError, "http_client_api timed out after #{max_wait_ms}ms")
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        total_requests = client_count * iterations
        total_bytes = total_requests * RESPONSE_BODY.bytesize

        {
          "requests_per_second" => total_requests / (finished_at - started_at),
          "bytes_per_second" => total_bytes / (finished_at - started_at),
          "fiber_duration_seconds" => Bench.summarize(samples)
        }
      ensure
        watchdog&.kill
        watchdog&.join
        server&.close
      end
    end
  end
end
