# frozen_string_literal: true

# Concurrent Net::HTTP GET requests fetching small JSON responses.
# Exercises the full Ruby HTTP stack (DNS, TCP connect, keep-alive, io_read/io_write).

require "net/http"
require_relative "http_client_support"

module AsyncBench
  module Workloads
    class HttpClientApi
      include HttpClientSupport

      RESPONSE_BODY = %({"ok":true,"value":12345})
      REQUEST_PATH = "/api"

      def call(options)
        client_count = Integer(options.fetch(:concurrency, 20))
        iterations = Integer(options.fetch(:iterations, 200))
        server = HttpClientSupport::LoopbackServer.new(
          response_body: RESPONSE_BODY,
          content_type: "application/json"
        )

        started_at = AsyncBench.monotonic_time

        Async do
          barrier = Async::Barrier.new

          client_count.times do
            barrier.async do
              Net::HTTP.start("127.0.0.1", server.port, nil, nil) do |http|
                iterations.times do
                  response = http.request(Net::HTTP::Get.new(REQUEST_PATH))
                  raise "unexpected status #{response.code}" unless response.code == "200"
                  raise "unexpected body size" unless response.body&.bytesize == RESPONSE_BODY.bytesize
                end
              end
            end
          end

          barrier.wait
        end

        elapsed = AsyncBench.monotonic_time - started_at
        total_requests = client_count * iterations

        {"requests_per_second" => total_requests / elapsed}
      ensure
        server&.close
      end
    end
  end
end
