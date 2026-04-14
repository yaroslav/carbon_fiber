# frozen_string_literal: true

# Please note that this code is heavily AI-assisted.

require "resolv"
require "socket"
require "timeout"
require_relative "native"

# High-performance Ruby Fiber Scheduler backed by Zig and libxev.
#
# Carbon Fiber implements the Ruby Fiber Scheduler protocol with a native
# event loop: io_uring on Linux, kqueue on macOS. Install it as the thread's
# scheduler and existing blocking I/O code becomes concurrent automatically.
#
# @example Basic usage
#   require "carbon_fiber"
#
#   Fiber.set_scheduler(CarbonFiber::Scheduler.new)
#   Fiber.schedule { Net::HTTP.get(URI(url)) }
#
# @example With the Async framework
#   require "carbon_fiber/async"
#   CarbonFiber::Async.default!
#
#   Async { |task| task.sleep(1) }
#
# @see CarbonFiber::Scheduler
# @see CarbonFiber::Async
module CarbonFiber
  # Implements the Ruby Fiber Scheduler interface.
  #
  # Delegates I/O and timer operations to a native Zig selector (io_uring on
  # Linux, kqueue on macOS). Operations the native layer doesn't cover
  # (DNS, process_wait) run on background threads.
  #
  # @example
  #   scheduler = CarbonFiber::Scheduler.new
  #   Fiber.set_scheduler(scheduler)
  #   Fiber.schedule { sleep 1; puts "done" }
  #   scheduler.run
  #   Fiber.set_scheduler(nil)
  class Scheduler
    # @param root_fiber [Fiber] the event loop fiber (defaults to current)
    # @param selector [Class] native selector class to instantiate
    def initialize(root_fiber = Fiber.current, selector: CarbonFiber::Native::Selector)
      @root_fiber = root_fiber
      @scheduler_thread = Thread.current
      @selector = selector.new(root_fiber)
      @active_fibers = 0
      @background_count = 0
      @closed = false
      @closing = false
    end

    # Called by Ruby when +Fiber.set_scheduler(nil)+ is invoked.
    def scheduler_close
      close(true)
    end

    # Drain pending work and release the native selector.
    def close(internal = false)
      return true if @closed || @closing

      unless internal
        return Fiber.set_scheduler(nil) if Fiber.scheduler == self
      end

      @closing = true
      run
      true
    ensure
      unless @closed
        @selector&.destroy
        @closed = true
        @closing = false
        freeze
      end
    end

    # @return [Boolean] whether the scheduler has been closed
    def closed?
      @closed
    end

    # Monotonic clock used by the scheduler for timers.
    # @return [Float] seconds since an arbitrary epoch
    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Create and schedule a non-blocking fiber.
    # @yield the block to run inside the fiber
    # @return [Fiber]
    def fiber(&block)
      fiber = Fiber.new(blocking: false) do
        block.call
      ensure
        fiber_done
      end

      @active_fibers += 1
      @selector.push(fiber)
      @selector.wakeup unless Thread.current.equal?(@scheduler_thread)

      fiber
    end

    # Transfer control to the next ready fiber or the event loop.
    def transfer
      @selector.transfer
    end

    # Re-enqueue the current fiber and transfer to the event loop.
    def yield
      @selector.yield
    end

    # Enqueue a fiber into the ready queue.
    # @param fiber [Fiber]
    def push(fiber)
      @selector.push(fiber)
    end

    # Resume a fiber, optionally passing a value.
    # @param fiber [Fiber]
    # @param arguments [Array] at most one value to pass to the fiber
    def resume(fiber, *arguments)
      if arguments.empty?
        @selector.push(fiber)
      else
        @selector.resume(fiber, arguments.first)
      end
    end

    # Deliver an exception to a suspended fiber.
    # @param fiber [Fiber]
    # @param exception [Exception]
    def raise(fiber, exception)
      @selector.raise(fiber, exception)
    end

    # Wake the event loop (thread-safe).
    def wakeup
      @selector.wakeup
    end

    # Run one iteration of the event loop.
    # @param timeout [Float, nil] maximum seconds to wait
    def select(timeout = nil)
      @selector.select(timeout)
    end

    # Suspend the current fiber until unblocked or timed out.
    # @param _blocker [Object] unused, required by the protocol
    # @param timeout [Float, nil] seconds before automatic resume
    def block(_blocker, timeout = nil)
      @selector.block(Fiber.current, timeout)
    end

    # Resume a fiber previously suspended by {#block}.
    # @param _blocker [Object] unused, required by the protocol
    # @param fiber [Fiber]
    def unblock(_blocker, fiber)
      @selector.unblock(fiber)
      true
    end

    # Intercept +Kernel#sleep+. Parks the fiber on a native timer.
    # @param duration [Float, nil] seconds to sleep; nil sleeps forever
    def kernel_sleep(duration = nil)
      if duration.nil?
        transfer
      elsif duration <= 0
        self.yield
      else
        block(nil, duration)
      end

      true
    end

    # Wait for I/O readiness on a file descriptor.
    # @param io [IO]
    # @param events [Integer] bitmask of +IO::READABLE+, +IO::WRITABLE+
    # @param timeout [Float, nil]
    # @return [Integer, false] readiness bitmask, or false on timeout
    def io_wait(io, events, timeout = nil)
      return poll_io_now(io, events) if timeout == 0

      # Native io_wait_object handles fileno extraction, Fiber.current,
      # and nil/numeric timeout in Zig — skipping a Ruby frame + branch
      # per call on Net::HTTP's hot read/write loop.
      result = @selector.io_wait_object(io, events, timeout)
      result.nil? ? await_background_operation { io_select_readiness(io, events, timeout) } : result
    rescue NoMethodError, TypeError
      await_background_operation { io_select_readiness(io, events, timeout) }
    end

    # Read from an IO into a buffer via the native selector.
    # Falls back to a background thread for non-socket descriptors.
    # @param io [IO]
    # @param buffer [IO::Buffer]
    # @param length [Integer]
    # @param offset [Integer]
    # @return [Integer] bytes read, or negative errno
    def io_read(io, buffer, length, offset = 0)
      # Native io_read_object extracts the descriptor in Zig, skipping a
      # `respond_to?(:fileno)` + `io.fileno` method-send pair per call.
      native_result = @selector.io_read_object(io, buffer, length, offset)
      return native_result unless native_result.nil?

      await_background_operation do
        Fiber.blocking { buffer.read(io, length, offset) }
      end
    rescue NoMethodError, TypeError
      await_background_operation do
        Fiber.blocking { buffer.read(io, length, offset) }
      end
    end

    # Write from a buffer to an IO via the native selector.
    # Falls back to a background thread for non-socket descriptors.
    # @param io [IO]
    # @param buffer [IO::Buffer]
    # @param length [Integer]
    # @param offset [Integer]
    # @return [Integer] bytes written, or negative errno
    def io_write(io, buffer, length, offset = 0)
      native_result = @selector.io_write_object(io, buffer, length, offset)
      return native_result unless native_result.nil?

      await_background_operation do
        Fiber.blocking { buffer.write(io, length, offset) }
      end
    rescue NoMethodError, TypeError
      await_background_operation do
        Fiber.blocking { buffer.write(io, length, offset) }
      end
    end

    # Blocking IO.select on a background thread.
    def io_select(...)
      await_background_operation do
        Fiber.blocking { IO.select(...) }
      end
    end

    # Cancel pending waiters on an IO and close the descriptor.
    # @param io [IO]
    def io_close(io)
      descriptor = io.respond_to?(:to_i) ? io.to_i : io
      @selector.io_close(descriptor, IOError.new("stream closed while waiting"))

      Fiber.blocking do
        target = io.is_a?(IO) ? io : IO.for_fd(descriptor.to_i)
        target.close unless target.closed?
      end

      true
    end

    # Wait for a child process on a background thread.
    # @param pid [Integer]
    # @param flags [Integer] waitpid flags
    # @return [Process::Status]
    def process_wait(pid, flags)
      # Ruby 4.0 bug: rb_process_status_wait re-enters the scheduler hook,
      # so native process_wait produces an incorrect status. Background-thread
      # waitpid avoids this because new threads have no scheduler installed.
      await_background_operation do
        if flags.zero?
          Process::Status.wait(pid, flags)
        else
          _waited_pid, status = Process.waitpid2(pid, flags)
          status
        end
      end
    end

    # Resolve a hostname to addresses via Resolv.
    # @param hostname [String]
    # @return [Array<String>]
    def address_resolve(hostname)
      if hostname.include?("%")
        hostname = hostname.split("%", 2).first
      end
      Resolv.getaddresses(hostname)
    end

    # Run an arbitrary callable on a background thread.
    # @param work [#call]
    def blocking_operation_wait(work)
      await_background_operation do
        work.call
      end
    end

    # Deliver an exception to a fiber from another fiber.
    # @param fiber [Fiber]
    # @param exception [Exception]
    def fiber_interrupt(fiber, exception)
      @selector.raise(fiber, exception)
      @selector.wakeup
      true
    end

    # Run a block with a timeout, raising an exception if it expires.
    # @param duration [Float] seconds
    # @param klass [Class, Exception] exception class or instance
    # @param message [String]
    def timeout_after(duration, klass = Timeout::Error, message = "execution expired", &block)
      exc = klass.is_a?(Class) ? klass.new(message) : klass
      token = @selector.raise_after(Fiber.current, exc, duration)
      block.call(duration)
    ensure
      @selector.cancel_timer(token) if token
    end

    # Run one event loop iteration. Alias for {#select}.
    def run_once(timeout = nil)
      @selector.select(timeout)
    end

    # Run the event loop until all fibers and background operations complete.
    def run
      Kernel.raise RuntimeError, "Scheduler has been closed" if closed?

      run_once until idle?
      true
    end

    private

    def idle?
      @active_fibers.zero? && @background_count.zero? && !@selector.pending?
    end

    def fiber_done
      @selector.cancel_block_timer(Fiber.current)
      @active_fibers -= 1 if @active_fibers.positive?
    end

    def await_background_operation(&block)
      fiber = Fiber.current
      box = {}

      Thread.new do
        Thread.current.report_on_exception = false

        begin
          box[:result] = block.call
          @selector.resume(fiber, true)
        rescue => e
          box[:error] = e
          @selector.resume(fiber, true)
        ensure
          @selector.wakeup
        end
      end

      @background_count += 1
      @selector.block(fiber, nil)

      Kernel.raise box[:error] if box[:error]

      box[:result]
    ensure
      @background_count -= 1 if @background_count.positive?
    end

    def poll_io_now(io, events)
      # Net::HTTP#begin_transport calls `wait_readable(0)` before every
      # keep-alive request to probe for a closed connection.  On a healthy
      # connection this is always "not readable", so returning false
      # directly saves one MSG_PEEK recvfrom per request.  On a genuinely
      # closed connection Net::HTTP will detect EOF on the next real read
      # and reconnect — one extra request's worth of latency, at most.
      return false if events == IO::READABLE && io.is_a?(BasicSocket)

      Fiber.blocking { io_select_readiness(io, events, 0) }
    end

    def io_select_readiness(io, events, timeout)
      readers = (events & IO::READABLE).zero? ? nil : [io]
      writers = (events & IO::WRITABLE).zero? ? nil : [io]
      ready = IO.select(readers, writers, nil, timeout)
      return false unless ready

      readiness = 0
      readiness |= IO::READABLE if ready[0]&.include?(io)
      readiness |= IO::WRITABLE if ready[1]&.include?(io)
      readiness.zero? ? false : readiness
    end
  end
end
