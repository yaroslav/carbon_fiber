# frozen_string_literal: true

# Please note that this code is heavily AI-assisted.

module CarbonFiber
  module Native
    # Pure-Ruby fallback selector using threads and condition variables.
    #
    # Loaded automatically when the native Zig extension is unavailable.
    # Provides the same Selector API as the native implementation so the
    # Scheduler and Async adapter work unchanged.
    class Selector
      # @param loop_fiber [Fiber] the event loop fiber
      def initialize(loop_fiber)
        @loop_fiber = loop_fiber
        @mutex = Thread::Mutex.new
        @cv = Thread::ConditionVariable.new
        @ready = []
        @timers = {}
        @next_timer = 1
        @read_waits = {}
        @next_wait_token = 1

        # Fibers voluntarily parked in block() or do_io_wait, mapped to the
        # sleep timer token (or nil). flush_ready consults this set to decide
        # whether a fiber whose transfer returned unexpectedly was interrupted
        # mid-execution (Ruby 4.0 Fiber#raise bypass) and needs re-queueing.
        @blocked_fibers = {}
      end

      # No-op; nothing to release.
      def destroy
        true
      end

      # @return [Boolean] whether there is pending work
      def pending?
        @mutex.synchronize { @ready.any? || @timers.any? || @read_waits.any? }
      end

      # Enqueue a fiber into the ready queue.
      def push(fiber)
        @mutex.synchronize do
          @ready << [:resume, fiber, nil, false]
          @cv.signal
        end
        fiber
      end

      # Enqueue a fiber with a return value.
      def resume(fiber, value)
        @mutex.synchronize do
          @ready << [:resume, fiber, value, true]
          @cv.signal
        end
        fiber
      end

      # Enqueue an exception delivery to a fiber.
      def raise(fiber, exception)
        @mutex.synchronize do
          # Cancel any armed sleep timer for this fiber so its block() wakeup
          # doesn't spuriously fire after the raise. Zero the token but leave
          # the blocked_fibers entry—it's removed by cancel_block_timer when
          # the fiber's ensure runs, so flush_ready's re-queue check still
          # correctly treats the fiber as "parked" until it exits.
          if @blocked_fibers.key?(fiber)
            token = @blocked_fibers[fiber]
            @timers.delete(token) if token
            @blocked_fibers[fiber] = nil
          end
          @ready << [:raise, fiber, exception, true]
          @cv.signal
        end
        fiber
      end

      # Wake the event loop.
      def wakeup
        @mutex.synchronize { @cv.signal }
        true
      end

      # Transfer control to the event loop fiber.
      def transfer
        return nil if Fiber.current.equal?(@loop_fiber)

        @loop_fiber.transfer
      end

      # Transfer to the event loop fiber. flush_ready's re-queue logic puts
      # us back in the ready queue on the next pass—no explicit self-push
      # needed, and avoiding it prevents duplicate ready entries.
      def yield
        return nil if Fiber.current.equal?(@loop_fiber)

        @loop_fiber.transfer
      end

      # Run one event loop iteration.
      def select(timeout = nil)
        flush_ready
        return 0 unless pending?

        deadline = next_wait_deadline(timeout)

        @mutex.synchronize do
          until @ready.any?
            collect_expired_timers_locked
            break if @ready.any?

            if deadline
              remaining = deadline - monotonic_time
              break if remaining <= 0

              @cv.wait(@mutex, remaining)
            else
              @cv.wait(@mutex)
            end
          end
        end

        collect_expired_timers
        flush_ready
      end

      # Suspend the current fiber until unblocked or timed out.
      def block(fiber, timeout = nil)
        token = nil
        token = resume_after(fiber, timeout, false) if timeout
        @mutex.synchronize { @blocked_fibers[fiber] = token }

        result = @loop_fiber.transfer

        # Normal wakeup path: drop the tracking entry and cancel any still-
        # armed sleep timer. If raise() ran first, it already cancelled the
        # timer and zeroed the token; the raise-unwind path then relies on
        # cancel_block_timer (invoked from fiber_done) to remove the entry.
        @mutex.synchronize do
          stored = @blocked_fibers.delete(fiber)
          @timers.delete(stored) if stored
        end
        result
      end

      # Resume a fiber previously suspended by {#block}.
      def unblock(fiber)
        resume(fiber, true)
      end

      # Schedule an exception to be raised on a fiber after +duration+ seconds.
      def raise_after(fiber, exception, duration)
        schedule_timer(duration, :raise, fiber, exception)
      end

      # Cancel a pending timer by token.
      def cancel_timer(token)
        @mutex.synchronize { !!@timers.delete(token) }
      end

      # Called from Scheduler#fiber_done's ensure block. Removes the fiber
      # from the blocked set and cancels any still-armed sleep timer. This is
      # the only cleanup path when a raise() unwinds the fiber past block()'s
      # normal return.
      def cancel_block_timer(fiber)
        @mutex.synchronize do
          stored = @blocked_fibers.delete(fiber)
          @timers.delete(stored) if stored
        end
      end

      # Wait for read readiness on a file descriptor via IO.select on
      # a background thread.
      # Returns nil for non-READABLE events (handled by the Scheduler fallback).
      def io_wait(fiber, fd, events)
        return nil unless events == IO::READABLE

        do_io_wait(fiber, fd, nil)
      end

      # Like {#io_wait} but with a timeout.
      def io_wait_with_timeout(fiber, fd, events, timeout)
        return nil unless events == IO::READABLE

        do_io_wait(fiber, fd, timeout)
      end

      # Cancel pending waiters on a closed descriptor.
      def io_close(fd, exception)
        woke = false

        @mutex.synchronize do
          wait = @read_waits.delete(fd)
          if wait
            @ready << [:raise, wait[:fiber], exception, true]
            woke = true
            @cv.signal
          end
        end

        woke
      end

      # Returns nil; the Scheduler handles process_wait via background thread.
      def process_wait(_fiber, _pid, _flags)
        nil
      end

      # Returns nil; the Scheduler handles io_read via background thread.
      def io_read(_fd, _buffer, _length, _offset)
        nil
      end

      # Returns nil; the Scheduler handles io_write via background thread.
      def io_write(_fd, _buffer, _length, _offset)
        nil
      end

      # Non-destructive check if a descriptor has data available to read.
      def poll_readable_now(fd)
        io = IO.new(fd, autoclose: false)
        ready = IO.select([io], nil, nil, 0)
        !!ready
      rescue IOError, SystemCallError
        false
      ensure
        io.close if io && !io.closed?
      end

      private

      def do_io_wait(fiber, fd, timeout)
        wait = @mutex.synchronize do
          break nil if @read_waits.key?(fd)

          token = @next_wait_token
          @next_wait_token += 1
          io = IO.new(fd, autoclose: false)
          @read_waits[fd] = {token: token, fiber: fiber, io: io}
        end

        return nil unless wait

        # Register as blocked before launching the worker—if the IO.select
        # returns immediately, the worker's resume push must land while we're
        # still marked parked so flush_ready doesn't treat our return as an
        # interrupt.
        @mutex.synchronize { @blocked_fibers[fiber] = nil }

        Thread.new do
          Thread.current.report_on_exception = false

          begin
            ready = IO.select([wait[:io]], nil, nil, timeout)
            @mutex.synchronize do
              current = @read_waits[fd]
              if current && current[:token] == wait[:token]
                @read_waits.delete(fd)
                payload = ready ? IO::READABLE : false
                @ready << [:resume, wait[:fiber], payload, true]
                @cv.signal
              end
            end
          rescue IOError, SystemCallError
          ensure
            wait[:io].close unless wait[:io].closed?
          end
        end

        result = @loop_fiber.transfer
        @mutex.synchronize { @blocked_fibers.delete(fiber) }
        result
      end

      def resume_after(fiber, duration, value)
        schedule_timer(duration, :resume, fiber, value)
      end

      def schedule_timer(duration, kind, fiber, payload)
        token = nil
        @mutex.synchronize do
          token = @next_timer
          @next_timer += 1
          @timers[token] = [monotonic_time + duration, kind, fiber, payload]
          @cv.signal
        end
        token
      end

      def next_wait_deadline(timeout)
        timer_deadline = @mutex.synchronize do
          @timers.values.map(&:first).min
        end

        timeout_deadline = timeout && (monotonic_time + timeout)

        if timer_deadline && timeout_deadline
          [timer_deadline, timeout_deadline].min
        else
          timer_deadline || timeout_deadline
        end
      end

      def collect_expired_timers
        now = monotonic_time
        expired = []

        @mutex.synchronize do
          collect_expired_timers_into(now, expired)
          @ready.concat(expired)
        end
      end

      def collect_expired_timers_locked
        expired = []
        collect_expired_timers_into(monotonic_time, expired)
        @ready.concat(expired)
      end

      def collect_expired_timers_into(now, expired)
        @timers.delete_if do |_token, (deadline, kind, fiber, payload)|
          next false if deadline > now

          expired << [kind, fiber, payload, true]
          true
        end
      end

      def flush_ready
        # Snapshot the batch boundary. Entries re-queued during dispatch (by
        # the Ruby 4.0 bypass handler below, or by fibers enqueueing new work
        # as they run) are deferred to the next flush_ready call—without
        # this cap, a yield-forever fiber would spin inside one call.
        batch_size = @mutex.synchronize { @ready.size }

        batch_size.times do
          kind, fiber, payload, has_payload = @mutex.synchronize { @ready.shift }
          break unless fiber
          next unless fiber.alive?

          case kind
          when :resume
            has_payload ? fiber.transfer(payload) : fiber.transfer

            # Ruby 4.0's Fiber#raise bypasses fiber_interrupt and returns
            # control to loop_fiber instead of the caller, stranding the
            # fiber that invoked raise. When flush_ready's transfer returns
            # with the fiber still alive AND not voluntarily parked, the
            # return was unexpected—re-queue so the fiber can finish.
            if fiber.alive?
              parked = @mutex.synchronize { @blocked_fibers.key?(fiber) }
              unless parked
                @mutex.synchronize { @ready << [:resume, fiber, nil, false] }
              end
            end
          when :raise
            fiber.raise(payload)
          end
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    module_function

    def available?
      false
    end

    def backend
      "ruby_fallback"
    end
  end
end
