# frozen_string_literal: true

require "net/http"
require_relative "http_client_support"

module Bench
  module Workloads
    class HttpClientDownload
      include HttpClientSupport

      REQUEST_PATH = "/download"
      DEFAULT_RESPONSE_BYTES = 262_144

      def call(_scheduler, options)
        client_count = Integer(options.fetch(:concurrency, 10))
        iterations = Integer(options.fetch(:iterations, 20))
        response_bytes = Integer(options.fetch(:response_bytes, DEFAULT_RESPONSE_BYTES))
        max_wait_ms = Float(options.fetch(:max_wait_ms, 10_000.0))
        body = ("download-chunk-".b * (response_bytes / 15.0).ceil)[0, response_bytes]
        samples = Array.new(client_count, 0.0)
        server = HttpClientSupport::LoopbackServer.new(
          response_body: body,
          content_type: "application/octet-stream"
        )
        started_at = Bench.monotonic_time
        benchmark_thread = Thread.current

        client_count.times do |index|
          Fiber.schedule do
            fiber_started_at = Bench.monotonic_time

            Net::HTTP.start("127.0.0.1", server.port, nil, nil) do |http|
              iterations.times do
                bytes_read = 0
                request = Net::HTTP::Get.new(REQUEST_PATH)

                http.request(request) do |response|
                  raise "unexpected status #{response.code}" unless response.code == "200"

                  response.read_body do |chunk|
                    bytes_read += chunk.bytesize
                  end
                end

                raise "unexpected body size" unless bytes_read == response_bytes
              end
            end

            samples[index] = Bench.monotonic_time - fiber_started_at
          end
        end

        watchdog = Thread.new do
          Thread.current.report_on_exception = false
          sleep(max_wait_ms / 1000.0)
          benchmark_thread.raise(RuntimeError, "http_client_download timed out after #{max_wait_ms}ms")
        end

        Fiber.scheduler.run
        finished_at = Bench.monotonic_time
        total_downloads = client_count * iterations
        total_bytes = total_downloads * response_bytes

        {
          "downloads_per_second" => total_downloads / (finished_at - started_at),
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
