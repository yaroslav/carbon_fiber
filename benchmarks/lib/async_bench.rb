# frozen_string_literal: true

require "benchmark"

module AsyncBench
  TARGETS = {
    "stock" => {
      setup: -> {}
    },
    "carbon" => {
      setup: -> {
        require_relative "../../lib/carbon_fiber"
        require "async"
        require_relative "../../lib/carbon_fiber/async"
        CarbonFiber::Async.default!
      }
    }
  }.freeze

  # Full workload registry.  The core default bench (`benchmarks/async_bench`
  # with no -w flag) runs `CORE_WORKLOADS` only.  Workloads listed here but
  # not in `CORE_WORKLOADS` are still runnable with `-w <name>`, and are
  # kept in the repo as regression canaries — they're just excluded from
  # the headline default suite because they don't meaningfully differentiate
  # backends (see notes below).
  WORKLOADS = {
    "http_client_api" => {defaults: {concurrency: 20, iterations: 200}, metric: "requests_per_second", unit: "req/s"},
    "http_client_download" => {defaults: {concurrency: 10, iterations: 20, response_bytes: 262_144}, metric: "downloads_per_second", unit: "dl/s"},
    "task_churn" => {defaults: {batch_size: 100, iterations: 200}, metric: "tasks_per_second", unit: "task/s"},
    "barrier_fanout" => {defaults: {coordinators: 10, fan_width: 10, iterations: 100}, metric: "cycles_per_second", unit: "cyc/s"},
    "sleep_storm" => {defaults: {fibers: 200, iterations: 50}, metric: "sleeps_per_second", unit: "slp/s"},
    "pipe_pipeline" => {defaults: {stages: 5, messages: 500, payload: 512}, metric: "messages_per_second", unit: "msg/s"},
    "condition_signal" => {defaults: {producers: 5, consumers: 20, messages: 200}, metric: "signals_per_second", unit: "sig/s"},
    "connection_pool" => {defaults: {concurrency: 50, iterations: 100}, metric: "checkouts_per_second", unit: "co/s"},
    "cascading_timeout" => {defaults: {concurrency: 20, iterations: 200}, metric: "operations_per_second", unit: "ops/s"},
    "tcp_throughput" => {defaults: {clients: 10, iterations: 200, payload: 512}, metric: "operations_per_second", unit: "ops/s"}
  }.freeze

  # Workloads included in the default core run.  Each entry exercises the
  # io-event / fiber-scheduler backend in a way where the choice of
  # implementation materially changes throughput.
  #
  # The following workloads are deliberately excluded from the default run
  # and kept in `WORKLOADS` only as opt-in canaries:
  #
  # - `sleep_storm`: 99% of wall time is in `sleep(0.5-5 ms)` between
  #   iterations.  Measures timer-wheel accuracy at millisecond granularity;
  #   every backend is pegged near the theoretical parallel floor, so
  #   deltas are sub-percent and don't discriminate implementations.
  #
  # - `pipe_pipeline`: kernel pipe read/write dominates.  The backend just
  #   hands buffers off to the kernel; per-byte copy + syscall cost
  #   dominates over the per-op scheduler cost.
  #
  # - `barrier_fanout`: most of the wall time is in `Async::Barrier`'s
  #   own Ruby code coordinating child tasks.  The backend is only
  #   consulted for the occasional `block`/`unblock` at the barrier
  #   boundary, which is a tiny fraction of the total.
  #
  # - `connection_pool`: `Async::Pool`'s Ruby `pool.rb` dominates.  The
  #   backend is only involved in the checkout/checkin `block`/`unblock`
  #   pair, which is again a tiny fraction of the total.
  #
  # `task_churn` stays in the default suite even though the carbon backend
  # has a known ~3-4% structural loss on it (the Ruby → C binding → Zig
  # method → `rb_fiber_transfer` path has more hops than stock io-event's
  # C-inline queue push, costing ~3000 extra instructions per task).  It
  # *does* exercise the scheduler hot path and is a fair measurement of
  # pure task-dispatch throughput — the loss is architectural and should
  # be reported honestly, not hidden by excluding the workload.
  #
  # Run the excluded workloads explicitly with e.g.
  # `benchmarks/async_bench -w sleep_storm` when you want a canary check
  # before a release.
  CORE_WORKLOADS = WORKLOADS.slice(
    "http_client_api",
    "http_client_download",
    "task_churn",
    "condition_signal",
    "cascading_timeout",
    "tcp_throughput"
  ).freeze

  module Workloads; end

  def self.classify(key)
    key.split("_").map(&:capitalize).join
  end

  def self.monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
