# Carbon Fiber

**High performance Ruby Fiber Scheduler powered by Zig and libxev.**

<div align="center">
  <img src="https://raw.githubusercontent.com/yaroslav/bundlebun/refs/heads/main/assets/images/carbon_fiber.jpg" width="600" height="400" alt="Carbon Fiber">
</div>

[![GitHub Release](https://img.shields.io/github/v/release/yaroslav/carbon_fiber)](https://github.com/yaroslav/carbon_fiber/releases)
[![Docs](https://img.shields.io/badge/yard-docs-blue.svg)](https://rubydoc.info/gems/carbon_fiber)

**Carbon Fiber is a Ruby Fiber Scheduler** with a native event loop (io_uring on Linux, kqueue on macOS). Install it, and your `Net::HTTP`, `TCPSocket`, `Mutex`, `Queue`, `Process.spawn` code becomes concurrent without any changes. Carbon Fiber also **supports the Async framework** ([async gem](https://github.com/socketry/async)) working as a plug and play backend.

By my benchmarks (follows), Carbon Fiber ends up being the **fastest pure Ruby Fiber Scheduler** currently available.

Carbon Fiber is implemented using the **Zig** programming language and is powered by **[libxev](https://github.com/mitchellh/libxev)** by Mitchell Hashimoto, used in his **Ghostty** terminal emulator. It is one of the first Ruby native extensions written in Zig.

## Features

- **Very fast.** My benchmarks place it as overall the fastest pure Ruby Fiber Scheduler. Uses **io_uring on Linux** and **kqueue on macOS**. 
- **Plug and play with plain Ruby**, thanks to the Fiber Scheduler API—`Net::HTTP`, `TCPSocket`, `Process.spawn`, `Mutex`, `Queue`, DNS—all transparently concurrent under the scheduler; no gem-specific wrappers required.
- **Async (gem async) support** as a swappable backend. One call swaps the [Async](https://github.com/socketry/async) event loop for ours.
- **Pure-Ruby fallback**—when the native extension isn't available (Windows, for instance), drops to pure Ruby 4.0+ code behind the same API.

## Example

```ruby
require "carbon_fiber"
Fiber.set_scheduler(CarbonFiber::Scheduler.new)

urls.each do |url|
  Fiber.schedule { Net::HTTP.get(URI(url)) }  # plain Net::HTTP, runs concurrently
end
```

---

## Contents

- [Performance](#performance)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [How It Works](#how-it-works)
- [Benchmarks](#benchmarks)
- [Acknowledgements](#acknowledgements)
- [License](#license)

---

## Performance

AWS EC2 c7a.2xlarge, 8 dedicated vCPUs, Ubuntu 24.04 LTS, kernel 6.17, Ruby 4.0.2 + YJIT, io_uring. 5-run median.

Some benchmarks:

| Workload | Carbon Fiber | Async | Itsi | Carbon Fiber vs. Async |
|---|---|---|---|---|
| `http_server` | **48.175k req/s** | 37.409k req/s | 29.708k req/s | +29% |
| `http_client_api` | **15.528k req/s** | 13.373k req/s | timeout | +16% |
| `http_client_download` | **6.747k dl/s** | 5.920k dl/s | timeout | +14% |
| `tcp_echo` | **50.392k ops/s** | 38.907k ops/s | 30.660k ops/s | +29% |
| `cascading_timeout` | **4.659k ops/s** | 4.488k ops/s | error | +4% |
| `connection_pool` | **4.989k co/s** | 4.912k co/s | 4.968k co/s | +2% |

On my workloads, wins almost all workloads across Async, Itsi, fiber_scheduler, io-event, and libev. [See detailed benchmarks →](#benchmarks)

---

## Requirements

- Ruby 3.4 or 4.0.

Distributed as aleady compiled and ready to use: Zig compiler _not_ needed.

## Installation

```
bundle add carbon_fiber
```

## Usage

### As a standalone fiber scheduler

Ruby's fiber scheduler protocol is built into the standard library. Install Carbon Fiber as the thread's scheduler and every blocking I/O call (`sleep`, `Net::HTTP.get`, `TCPSocket.new`, `Process::Status.wait`) yields automatically—no callbacks, no special wrappers.

See also: [Ruby Fiber Scheduler protocol](https://ruby-doc.org/core/Fiber/Scheduler.html).

#### Example: Parallel file downloads

Fetch a batch of files concurrently. Each fiber yields to the event loop while waiting for data; the scheduler runs all of them on a single thread.

```ruby
require "carbon_fiber"

require "net/http"
require "uri"

urls = %w[
  http://files.example.net/archive-1.tar.gz
  http://files.example.net/archive-2.tar.gz
  http://files.example.net/archive-3.tar.gz
]

scheduler = CarbonFiber::Scheduler.new
Fiber.set_scheduler(scheduler)

results = {}
urls.each do |url|
  Fiber.schedule do
    results[url] = Net::HTTP.get(URI(url))
  end
end

scheduler.run
Fiber.set_scheduler(nil)

puts "Downloaded #{results.size} files (#{results.values.sum(&:bytesize)} bytes total)"
```

The `Net::HTTP` code is unchanged from a sequential version. The scheduler intercepts every socket read and write, parks the fiber, and resumes it when the kernel signals readiness—all three downloads proceed in parallel.

#### Example: Parallel subprocess processing

Transcode a batch of video files using multiple `ffmpeg` processes, all monitored concurrently. `Process::Status.wait` yields to the scheduler while the child runs; no polling required.

```ruby
require "carbon_fiber"

jobs = {
  "output-1080p.mp4" => ["ffmpeg", "-i", "input.mov", "-vf", "scale=1920:1080", "output-1080p.mp4"],
  "output-720p.mp4"  => ["ffmpeg", "-i", "input.mov", "-vf", "scale=1280:720",  "output-720p.mp4"],
  "output-480p.mp4"  => ["ffmpeg", "-i", "input.mov", "-vf", "scale=854:480",   "output-480p.mp4"],
}

scheduler = CarbonFiber::Scheduler.new
Fiber.set_scheduler(scheduler)

statuses = {}
jobs.each do |label, cmd|
  Fiber.schedule do
    pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
    statuses[label] = Process::Status.wait(pid)
  end
end

scheduler.run
Fiber.set_scheduler(nil)

statuses.each do |label, status|
  puts "#{label}: #{status.success? ? "ok" : "exit #{status.exitstatus}"}"
end
```

All three `ffmpeg` processes run in parallel. The scheduler uses a background thread per `process_wait` call and parks the fiber until the process exits.

---

### With the Async framework

Carbon Fiber implements the `IO::Event::Selector` interface, so it can replace Async's built-in event loop. Call `CarbonFiber::Async.default!` once at startup; every subsequent `Async { }` block uses our backend.

```ruby
require "async"
require "carbon_fiber/async"
CarbonFiber::Async.default!
```

Alternatively, set the environment variable: `IO_EVENT_SELECTOR=CarbonFiberSelector ruby app.rb`.

#### Example: Fan-out API calls

Call multiple upstream endpoints in parallel using `Async::Barrier`, then wait for all results. 

```ruby
require "async"
require "async/barrier"
require "carbon_fiber/async"

require "net/http"
require "json"

CarbonFiber::Async.default!

ENDPOINTS = %w[/users /orders /products /inventory /settings]

Async do
  barrier = Async::Barrier.new
  results = {}

  ENDPOINTS.each do |path|
    barrier.async do
      response = Net::HTTP.get_response(URI("http://api.example.com#{path}"))
      results[path] = JSON.parse(response.body)
    end
  end

  barrier.wait

  puts "Loaded #{results.size} resources"
  results
end
```

#### Example: Rate-limited concurrent crawl

Fetch many pages concurrently while keeping no more than 10 connections open at once. `Async::Semaphore` limits in-flight requests; `Async::Barrier` tracks completion.

```ruby
require "async"
require "async/barrier"
require "async/semaphore"
require "carbon_fiber/async"

require "net/http"

CarbonFiber::Async.default!

pages = (1..200).map { |i| "http://data.example.com/records?page=#{i}" }

Async do
  barrier   = Async::Barrier.new
  semaphore = Async::Semaphore.new(10, parent: barrier)
  results   = []

  pages.each do |url|
    semaphore.async do
      results << Net::HTTP.get(URI(url))
    end
  end

  barrier.wait
  puts "Fetched #{results.size} pages"
end
```

---

## How It Works

The scheduler has two layers:

1. **Zig native core** (`ext/carbon_fiber_native/`) owns the event loop (libxev), ready queue, timer heap, and fiber chaining. Handles `io_wait`, `io_read`, `io_write`, `block`/`unblock`, timer-based sleep, and `timeout_after` directly in native code.

2. **Ruby shell** (`lib/carbon_fiber/scheduler.rb`) implements the Ruby Fiber Scheduler protocol, delegates to the native Selector, and falls back to a background thread for operations the native core doesn't cover (DNS, `process_wait`).

**Fiber chaining:** when a fiber parks, the native event loop calls `rb_fiber_transfer` directly to the next ready fiber, skipping a round-trip through the root fiber. This removes one context switch per scheduling decision on every `sleep`, `read`, and `write`.

If the native extension can't be loaded (on Windows, for example), a pure-Ruby fallback (`lib/carbon_fiber/native/fallback.rb`) provides the same Selector API using threads and condition variables.

---

## Benchmarks

AWS EC2 c7a.2xlarge, 8 dedicated vCPUs,Ubuntu 24.04 LTS, kernel 6.17, Ruby 4.0.2 + YJIT, io_uring. 5-run median.

### Ruby Fiber Schedulers (leading ones): Carbon Fiber vs. Async vs. Itsi

Measuring pure Ruby Fiber Scheduler performance (`Fiber.set_scheduler`).

| Workload | Unit | Carbon Fiber | Async | Itsi | Carbon Fiber vs. Async |
|---|---|---|---|---|---|
| `http_client_api` | req/s | **15,528** | 13,373 | timeout | +16% |
| `http_client_download` | dl/s | **6,747** | 5,920 | timeout | +14% |
| `http_server` | req/s | **48,175** | 37,409 | 29,708 | +29% |
| `tcp_echo` | ops/s | **50,392** | 38,907 | 30,660 | +29% |
| `connection_pool` | co/s | **4,989** | 4,912 | 4,968 | +2% |
| `fan_out_gather` | cyc/s | 2,024 | 2,046 | **2,104** | −1% |
| `db_query_mix` | qry/s | 1,660 | 1,652 | **1,662** | +0.5% |
| `cascading_timeout` | ops/s | **4,659** | 4,488 | error | +4% |

Enabling YJIT turned out to be very beneficial for Async as well—numbers here are with `--yjit` on both sides.

### Async framework: stock Async vs. Async + Carbon Fiber backend

Swapped the io-event selector for Carbon Fiber's native backend. Same Async code.

| Workload | Unit | Stock Async | Carbon Fiber | Delta |
|---|---|---|---|---|
| `http_client_api` | req/s | 13,375 | **14,331** | +7.1% |
| `http_client_download` | dl/s | 3,893 | **3,956** | +1.6% |
| `task_churn` | task/s | **87,883** | 85,027 | −3.3% |
| `condition_signal` | sig/s | 337,282 | **361,089** | +7.1% |
| `cascading_timeout` | ops/s | 4,497 | **4,511** | +0.3% |
| `tcp_throughput` | ops/s | 42,292 | **51,930** | +22.8% |

### Examples of how to run benchmarks

See [README](benchmarks/README.md) in the `benchmarks/` directory.

```bash
# macOS smoke test
benchmarks/bench -t carbon,async -w http_client_api,tcp_echo

# Linux via Docker (io_uring)
benchmarks/core_docker -t carbon,async,itsi -r 5

# Async framework comparison
benchmarks/async_docker -r 5
```

Note that your results will differ depending on the operating system (io_uring or kqueue), system load and hardware, and there will be a lot of variance with certain workloads anyway. Try to benchmark on dedicated hardware, with setup (operating system, kernel) close to your production environment.

---

## Acknowledgements

Thanks to Mitchell Hashimoto for [libxev](https://github.com/mitchellh/libxev) (and Ghostty).

Thanks to furunkel for [zig.rb](https://github.com/furunkel/zig.rb).

Thanks to Samuel Williams for the [Async](https://github.com/socketry/async) framework and [ecosystem](https://github.com/socketry).

## License

MIT
