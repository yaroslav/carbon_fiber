# frozen_string_literal: true

# Concurrent Net::HTTP GET requests streaming 256KB response bodies.
# Exercises io_read hot path with large payloads over keep-alive connections.

require "net/http"
require_relative "http_client_support"

module AsyncBench
  module Workloads
    class HttpClientDownload
      include HttpClientSupport

      REQUEST_PATH = "/download"
      DEFAULT_RESPONSE_BYTES = 262_144

      def call(options)
        client_count = Integer(options.fetch(:concurrency, 10))
        iterations = Integer(options.fetch(:iterations, 20))
        response_bytes = Integer(options.fetch(:response_bytes, DEFAULT_RESPONSE_BYTES))
        body = ("download-chunk-".b * (response_bytes / 15.0).ceil)[0, response_bytes]
        server = HttpClientSupport::LoopbackServer.new(
          response_body: body,
          content_type: "application/octet-stream"
        )

        started_at = AsyncBench.monotonic_time

        Async do
          barrier = Async::Barrier.new

          client_count.times do
            barrier.async do
              Net::HTTP.start("127.0.0.1", server.port, nil, nil) do |http|
                iterations.times do
                  bytes_read = 0

                  http.request(Net::HTTP::Get.new(REQUEST_PATH)) do |response|
                    raise "unexpected status #{response.code}" unless response.code == "200"

                    response.read_body do |chunk|
                      bytes_read += chunk.bytesize
                    end
                  end

                  raise "unexpected body size" unless bytes_read == response_bytes
                end
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_downloads = client_count * iterations

        {"downloads_per_second" => total_downloads / elapsed}
      ensure
        server&.close
      end
    end
  end
end
