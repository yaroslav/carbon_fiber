# frozen_string_literal: true

module Bench
  TARGETS = {
    "carbon" => {
      require_proc: -> { require_relative "../../lib/carbon_fiber" },
      constant: "CarbonFiber::Scheduler"
    },
    "async" => {
      gems: [["async", "2.38.1"]],
      require_proc: -> { require "async" },
      constant: "Async::Scheduler"
    },
    "itsi" => {
      gems: [["itsi-scheduler", "0.2.22"]],
      require_proc: -> { require "itsi/scheduler" },
      constant: "Itsi::Scheduler"
    },
    "evt" => {
      gems: [["evt"]],
      require_proc: -> {
        require "evt"
        # evt's io_wait returns true instead of the events bitmask Ruby expects
        Evt::Scheduler.prepend(Module.new do
          def io_wait(io, events, duration = nil)
            super
            events
          end
        end)
      },
      constant: "Evt::Scheduler",
      ruby: "3.4"
    },
    "fiber_scheduler" => {
      gems: [["fiber_scheduler"]],
      require_proc: -> {
        require "fiber_scheduler"
        # Ruby 3.4 added 4th offset parameter to io_read/io_write
        FiberScheduler.prepend(Module.new do
          def io_read(io, buffer, length, offset = 0)
            super(io, buffer, length)
          end

          def io_write(io, buffer, length, offset = 0)
            super(io, buffer, length)
          end
        end)
      },
      constant: "FiberScheduler",
      ruby: "3.4"
    },
    "libev" => {
      gems: [["libev_scheduler"]],
      require_proc: -> {
        require "libev_scheduler"
        # libev's io_wait returns self instead of the events bitmask Ruby expects
        Libev::Scheduler.prepend(Module.new do
          def io_wait(io, events, duration = nil)
            super
            events
          end
        end)
      },
      constant: "Libev::Scheduler",
      ruby: "3.4"
    }
  }.freeze

  # Full workload registry.  The core default bench (`benchmarks/bench` with
  # no -w flag) runs `CORE_WORKLOADS` only.  Workloads listed here but not in
  # `CORE_WORKLOADS` are still runnable with `-w <name>`, and are kept in the
  # repo as regression canaries — they're just excluded from the headline
  # default suite because they don't meaningfully differentiate schedulers
  # (see notes below).
  WORKLOADS = {
    "http_client_api" => {defaults: {concurrency: 20, iterations: 200}, metric: "requests_per_second", unit: "req/s"},
    "http_client_download" => {defaults: {concurrency: 20, iterations: 100}, metric: "downloads_per_second", unit: "dl/s"},
    "http_server" => {defaults: {concurrency: 20, iterations: 200}, metric: "requests_per_second", unit: "req/s"},
    "tcp_echo" => {defaults: {concurrency: 20, iterations: 200, payload_bytes: 512}, metric: "operations_per_second", unit: "ops/s"},
    "connection_pool" => {defaults: {concurrency: 50, iterations: 100}, metric: "checkouts_per_second", unit: "co/s"},
    "fan_out_gather" => {defaults: {concurrency: 10, iterations: 100}, metric: "gather_cycles_per_second", unit: "cyc/s"},
    "db_query_mix" => {defaults: {concurrency: 20, iterations: 100}, metric: "queries_per_second", unit: "qry/s"},
    "cascading_timeout" => {defaults: {concurrency: 20, iterations: 200}, metric: "operations_per_second", unit: "ops/s"},
    "mixed_io_sizes" => {defaults: {concurrency: 20, iterations: 50}, metric: "bytes_per_second", unit: "B/s"},
    "websocket_idle" => {defaults: {concurrency: 50, iterations: 100}, metric: "pings_per_second", unit: "ping/s"},
    "dns_fanout" => {defaults: {concurrency: 20, iterations: 50}, metric: "resolutions_per_second", unit: "res/s"}
  }.freeze

  # Workloads included in the default core run.  Each entry exercises the
  # Ruby Fiber Scheduler hot path in a way where the choice of backend
  # materially changes throughput.
  #
  # The following workloads are deliberately excluded from the default run
  # and kept in `WORKLOADS` only as opt-in canaries:
  #
  # - `dns_fanout`: calls `Addrinfo.getaddrinfo` directly, which bypasses
  #   the scheduler's `address_resolve` hook entirely.  Every Fiber
  #   Scheduler makes the same blocking libc/nss call, so any delta is
  #   pure CPU noise rather than a scheduler signal.
  #
  # - `websocket_idle`: 99% of wall time is in `sleep(0.010)`.  Measures
  #   timer-wheel accuracy at millisecond granularity; every modern
  #   scheduler is pegged at the theoretical ~1s parallel floor for 50×100
  #   ping/pong cycles, so deltas here are sub-percent and don't
  #   discriminate implementations.
  #
  # - `mixed_io_sizes`: dominated by kernel memcpy on 256 KB recvs.  The
  #   scheduler just hands the buffer off to the kernel; the per-byte
  #   copy cost dominates the per-op cost, and neither implementation has
  #   leverage on it.
  #
  # Run them explicitly with e.g. `benchmarks/bench -w dns_fanout` when
  # you want a canary check (e.g. before a release) to catch a regression
  # that would make the scheduler do genuinely worse on these paths.  The
  # default suite skips them so the headline comparison focuses on rows
  # where the backend choice actually matters.
  CORE_WORKLOADS = WORKLOADS.slice(
    "http_client_api",
    "http_client_download",
    "http_server",
    "tcp_echo",
    "connection_pool",
    "fan_out_gather",
    "db_query_mix",
    "cascading_timeout"
  ).freeze

  module Workloads; end

  def self.classify(key)
    key.split("_").map(&:capitalize).join
  end

  def self.constantize(name)
    name.split("::").reduce(Object) { |mod, part| mod.const_get(part) }
  end

  def self.monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.summarize(samples)
    sorted = Array(samples).compact.map(&:to_f).sort
    return {} if sorted.empty?

    {
      "count" => sorted.length,
      "min" => sorted.first,
      "max" => sorted.last,
      "mean" => sorted.sum / sorted.length,
      "p50" => sorted[(0.50 * (sorted.length - 1)).round],
      "p95" => sorted[(0.95 * (sorted.length - 1)).round],
      "p99" => sorted[(0.99 * (sorted.length - 1)).round]
    }
  end

  def self.fmt(value)
    return value.to_s unless value.is_a?(Numeric)

    if value.abs >= 1_000_000_000
      format("%.3fG", value / 1_000_000_000.0)
    elsif value.abs >= 1_000_000
      format("%.3fM", value / 1_000_000.0)
    elsif value.abs >= 1_000
      format("%.3fk", value / 1_000.0)
    else
      format("%.1f", value)
    end
  end
end
