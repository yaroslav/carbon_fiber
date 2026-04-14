# Benchmarks

Benchmark framework for comparing Ruby Fiber Scheduler implementations. Pure Ruby, ASCII table output, works identically on macOS (local) and Linux (Docker with io_uring).

Note that the benchmark code is heavily AI-assisted.

## Quick start

```bash
# Single target, single workload
benchmarks/bench -t carbon -w tcp_echo

# Two targets, delta column
benchmarks/bench -t carbon,async -w tcp_echo,http_server

# All workloads, 3 runs (median)
benchmarks/bench -t carbon,async -r 3

# Linux via Docker (arm64, io_uring)
benchmarks/core_docker -t carbon,async -w tcp_echo
```

## Setup

Targets other than `carbon` need their gems installed first:

```bash
# Install gems for specific targets
benchmarks/bench --setup -t async,itsi

# Install gems for all targets
benchmarks/bench --setup
```

Gems are installed per-target under `benchmarks/.gems/<target>/` (local) or `/workspace/tmp/linux_gems/<target>/` (Docker). The `.gems/` directory is gitignored.

`core_docker` runs `--setup` automatically before benchmarking.

## CLI reference

### `benchmarks/bench`

Orchestrator. Spawns each (target, workload) combination as an isolated subprocess, collects results, prints an ASCII table.

```
Usage: bench [options]
    -t, --targets LIST     Comma-separated target IDs (default: all)
    -w, --workloads LIST   Comma-separated workload IDs (default: all)
    -r, --runs N           Number of runs per combo, takes median (default: 1)
        --timeout N        Per-workload timeout in seconds (default: 30)
        --setup            Install target gems and exit
```

Environment variables:

| Variable | Description | Default |
|---|---|---|
| `BENCH_GEM_HOME` | Root directory for per-target gem installs | `benchmarks/.gems` |
| `BENCH_TIMEOUT` | Per-workload timeout in seconds | `30` |

Output goes to stdout (the table). Progress and setup messages go to stderr.

When exactly 2 targets are specified, a delta column shows the percentage change from the first target to the second.

### `benchmarks/bench_one`

Worker subprocess. Not meant to be called directly. Loads one target scheduler, runs one workload, prints a single floating-point metric value to stdout.

```
Usage: bench_one <target> <workload>
```

### `benchmarks/core_docker`

Docker wrapper. Builds the container, mounts the workspace, builds the native extension, installs gems, and runs `benchmarks/bench` with the provided arguments.

```bash
# Specific targets and workloads
benchmarks/core_docker -t carbon,async -w tcp_echo,http_server

# All targets, all workloads
benchmarks/core_docker

# Setup only (install gems, don't run)
benchmarks/core_docker --setup
```

Requires Docker. The container runs native arm64 on Apple Silicon (not x86 emulation). Uses `--security-opt seccomp=unconfined` and `--ulimit memlock=-1` for io_uring support.

## Targets

| ID | Scheduler | Gem |
|---|---|---|
| `carbon` | `CarbonFiber::Scheduler` | (local, Zig native ext) |
| `async` | `Async::Scheduler` | `async 2.38.1` |
| `itsi` | `Itsi::Scheduler` | `itsi-scheduler 0.2.22` |
| `evt` | `Evt::Scheduler` | `evt` |
| `fiber_scheduler` | `FiberScheduler` | `fiber_scheduler` |
| `io_event` | `RubyHarness::Vendor::IOEvent::Scheduler` | `io-event` |
| `libev` | `Libev::Scheduler` | `libev_scheduler` |
| `ruby_test` | `RubyHarness::Vendor::RubyTestScheduler` | (vendored) |
| `em_fiber` | `EventMachine::FiberScheduler` | `eventmachine` |

Primary comparison targets: `carbon`, `async`, `itsi`.

## Workloads

| ID | Metric | Unit | What it measures |
|---|---|---|---|
| `http_client_api` | `requests_per_second` | req/s | Net::HTTP GET over keep-alive to loopback server (small JSON) |
| `http_client_download` | `downloads_per_second` | dl/s | Net::HTTP GET streaming 256KB response bodies |
| `http_server` | `requests_per_second` | req/s | Fiber-per-connection HTTP/1.1 server with keep-alive clients |
| `tcp_echo` | `operations_per_second` | ops/s | TCP loopback echo (send payload, receive echo) |
| `connection_pool` | `checkouts_per_second` | co/s | N fibers competing for M pooled resources (block/unblock) |
| `fan_out_gather` | `gather_cycles_per_second` | cyc/s | Fan-out N parallel sleeps, gather results (barrier pattern) |
| `db_query_mix` | `queries_per_second` | qry/s | Simulated Rails DB pattern: pool checkout, 3-5 queries, checkin |
| `cascading_timeout` | `operations_per_second` | ops/s | timeout_after under load (70% fast, 30% killed by timeout) |
| `mixed_io_sizes` | `bytes_per_second` | B/s | Small (64B) and large (256KB) TCP transfers running concurrently |
| `websocket_idle` | `pings_per_second` | ping/s | Many idle connections with periodic ping/pong |
| `dns_fanout` | `resolutions_per_second` | res/s | Concurrent hostname resolution via Addrinfo.getaddrinfo |

### Default parameters

Each workload has baked-in defaults (concurrency, iterations, etc.) defined in `Bench::WORKLOADS`. These are tuned for stable, comparable results:

| Workload | Concurrency | Iterations | Other |
|---|---:|---:|---|
| `http_client_api` | 20 | 200 | |
| `http_client_download` | 20 | 100 | |
| `http_server` | 20 | 200 | |
| `tcp_echo` | 20 | 200 | payload_bytes: 512 |
| `connection_pool` | 50 | 100 | |
| `fan_out_gather` | 10 | 100 | |
| `db_query_mix` | 20 | 100 | |
| `cascading_timeout` | 20 | 200 | |
| `mixed_io_sizes` | 20 | 50 | |
| `websocket_idle` | 50 | 100 | |
| `dns_fanout` | 20 | 50 | |

### Priority

`http_client_api` and `http_client_download` are the most important benchmarks. They exercise the full Ruby I/O stack (Net::HTTP, io_read/io_write, keep-alive connections) and represent the most common real-world Ruby workload: making HTTP requests to upstream services.

Linux numbers matter more than macOS for all benchmarks.

## Async benchmarks

Separate benchmark suite comparing stock Async vs Async with the CarbonFiber backend (IO::Event::Selector replacement).

```bash
# macOS (local)
benchmarks/async_bench -t stock,carbon -w task_churn -r 3

# Linux via Docker
benchmarks/async_docker -r 3
```

### `benchmarks/async_bench`

Orchestrator for async benchmarks. Same CLI interface as `bench`.

```
Usage: async_bench [options]
    -t, --targets LIST     Comma-separated target IDs: stock, carbon (default: all)
    -w, --workloads LIST   Comma-separated workload IDs (default: all)
    -r, --runs N           Number of runs per combo, takes median (default: 1)
        --timeout N        Per-workload timeout in seconds (default: 30)
```

### `benchmarks/async_docker`

Docker wrapper for async benchmarks. Builds the container, builds the native extension, installs the `async` gem, and runs `async_bench`.

### Async workloads

| ID | Metric | Unit | What it measures |
|---|---|---|---|
| `task_churn` | `tasks_per_second` | task/s | Rapid fiber create/schedule/complete (scheduler overhead) |
| `barrier_fanout` | `cycles_per_second` | cyc/s | Fan-out N tasks behind Async::Barrier, gather results |
| `sleep_storm` | `sleeps_per_second` | slp/s | Many concurrent Async::Task sleeps (timer management) |
| `pipe_pipeline` | `messages_per_second` | msg/s | Multi-stage IO.pipe pipeline (io_read/io_write hot path) |
| `condition_signal` | `signals_per_second` | sig/s | Async::Condition producer/consumer signaling |
| `tcp_throughput` | `operations_per_second` | ops/s | TCP echo via Async's IO wrappers |

## Architecture

```
benchmarks/
  bench                  # Orchestrator: CLI, subprocess spawning, ASCII table
  bench_one              # Worker: load target, run workload, print metric
  core_docker            # Docker wrapper: build, setup, run
  async_bench            # Async orchestrator: stock vs carbon backend
  async_bench_one        # Async worker: load backend, run workload, print metric
  async_docker           # Docker wrapper for async benchmarks
  Dockerfile             # Linux arm64 build environment (Ruby 3.4 + Zig)
  README.md              # This file
  lib/
    bench.rb             # TARGETS + WORKLOADS registries, helpers
    async_bench.rb       # Async TARGETS + WORKLOADS registries
    bench/
      workloads/         # 11 core workload implementations
    async_bench/
      workloads/         # 6 async workload implementations
```

### Process isolation

Each (target, workload) runs in its own Ruby process via `bench_one`. This is necessary because:

1. `Fiber.set_scheduler` is process-global — different scheduler gems can't coexist
2. Scheduler gems load native extensions that may conflict
3. A crash in one workload doesn't kill the entire run

The orchestrator (`bench`) spawns `bench_one` subprocesses, captures stdout (a single number), and enforces timeouts via `Process.kill`.

### Data flow

```
bench (orchestrator)
  │
  ├─ spawn: ruby bench_one carbon tcp_echo
  │    └─ stdout: "24499.123"
  │
  ├─ spawn: ruby bench_one async tcp_echo
  │    └─ stdout: "22288.456"
  │
  └─ collect results, compute medians, print table
```

### Workload contract

Each workload is a class under `Bench::Workloads` with a single `call(scheduler, options)` method. It returns a hash containing at minimum the metric key specified in `Bench::WORKLOADS` (e.g., `"requests_per_second"`). The class name is derived from the workload key via `Bench.classify` (e.g., `tcp_echo` becomes `TcpEcho`).

### Adding a new workload

1. Create `benchmarks/lib/bench/workloads/my_workload.rb`
2. Define `Bench::Workloads::MyWorkload` with a `call(scheduler, options)` method
3. Return a hash including the metric key (e.g., `"operations_per_second" => value`)
4. Add entry to `Bench::WORKLOADS` in `benchmarks/lib/bench.rb`:
   ```ruby
   "my_workload" => { defaults: { concurrency: 20, iterations: 100 }, metric: "operations_per_second", unit: "ops/s" },
   ```

### Adding a new target

Add entry to `Bench::TARGETS` in `benchmarks/lib/bench.rb`:

```ruby
"my_sched" => {
  gem: ["my-scheduler-gem", "1.0.0"],  # omit for local/vendored
  require_proc: -> { require "my_scheduler" },
  constant: "MyScheduler::Scheduler",
},
```

## Platform notes

### macOS

- Uses kqueue (no io_uring)
- Some workloads (websocket_idle) need `--timeout 60` due to inherent timing
- Async may outperform carbon on some workloads — macOS is not the target platform
- Requires mise for Ruby/Zig toolchain: `eval "$(/opt/homebrew/opt/mise/bin/mise activate bash)"`

### Linux (Docker)

- Uses io_uring when available (the target configuration)
- Native arm64 on Apple Silicon — no x86 emulation
- `core_docker` handles everything: container build, native ext compilation, gem setup, benchmarking
- Needs `seccomp=unconfined` and `ulimit memlock=-1` for io_uring

### Interpreting results

- Single runs have variance. Use `-r 3` or `-r 5` for stable numbers.
- Docker benchmarks have more variance than bare-metal. Differences under 10% should be verified on bare metal.
- The delta column shows `(target2 - target1) / target1 * 100%`. Positive means target2 is faster.
- `error` means the subprocess exited non-zero. `timeout` means it exceeded the deadline.
