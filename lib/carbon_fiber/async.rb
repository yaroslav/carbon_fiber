# frozen_string_literal: true

# Please note that this code is heavily AI-assisted.

require_relative "native"

module CarbonFiber
  module Async
    # IO::Event::Selector-compatible adapter backed by our native Zig selector.
    # Subclasses Native::Selector so hot-path methods (transfer, yield, wakeup)
    # dispatch directly to native code without an extra Ruby method frame.
    #
    # Registration:
    #   require "async"
    #   require "carbon_fiber/async"
    #   CarbonFiber::Async.default!
    #
    # Or via environment:
    #   IO_EVENT_SELECTOR=CarbonFiberSelector ruby app.rb
    #
    class Selector < CarbonFiber::Native::Selector
      # @return [Float] seconds spent idle in the last {#select} call
      attr_reader :idle_duration

      # @return [Fiber] the event loop fiber
      attr_reader :loop

      # @param loop [Fiber] the Async event loop fiber
      def initialize(loop)
        super
        @loop = loop
        @idle_duration = 0.0

        # Auxiliary ready queue for non-Fiber pushables (e.g. FiberInterrupt)
        # and cross-thread pushes of non-Fiber objects. Thread-safe via mutex.
        @auxiliary = []
        @auxiliary_mutex = Mutex.new
      end

      # transfer:  inherited from native (no override needed)
      # yield:     inherited from native (no override needed)
      # wakeup:    inherited from native (no override needed)

      # Release native resources.
      def close
        destroy
      end

      # Enqueue a fiber or fiber-like object into the ready queue.
      # @param fiber [Fiber, Object]
      def push(fiber)
        if fiber.is_a?(Fiber)
          super
        else
          @auxiliary_mutex.synchronize { @auxiliary << fiber }
        end
      end

      # Re-enqueue the current fiber and transfer to +fiber+ with arguments.
      # @param fiber [Fiber]
      # @param arguments [Array]
      def resume(fiber, *arguments)
        current = Fiber.current
        native_push(current) unless current.equal?(@loop)
        fiber.transfer(*arguments)
      end

      # Re-enqueue the current fiber and raise on +fiber+.
      # @param fiber [Fiber]
      def raise(fiber, *arguments, **options)
        current = Fiber.current
        native_push(current) unless current.equal?(@loop)
        fiber.raise(*arguments, **options)
      end

      # @return [Boolean] whether there is pending work
      def ready?
        !@auxiliary.empty? || pending?
      end

      # --- Event loop ---

      # Run one event loop iteration, draining the auxiliary queue before
      # and after the native select.
      #
      # Note: +idle_duration+ is not actually measured—it stays at 0.0.
      # Async uses it for load stats only (not correctness), and the two
      # +Process.clock_gettime+ calls plus Float allocation cost ~1-2%
      # on select-heavy workloads.
      # @param duration [Float, nil] maximum seconds to wait
      def select(duration = nil)
        drain_auxiliary
        super
        drain_auxiliary
      end

      # --- IO operations ---

      # Wait for I/O readiness. Falls back to IO.select on a background
      # thread when the native path returns nil (kqueue WRITE bypass,
      # closed fd, duplicate waiter).
      # @param fiber [Fiber]
      # @param io [IO]
      # @param events [Integer] bitmask of +IO::READABLE+, +IO::WRITABLE+
      # @return [Integer, false] readiness bitmask, or false on timeout
      def io_wait(fiber, io, events)
        result = native_io_wait(fiber, io.fileno, events)
        return result unless result.nil?

        fallback_io_wait(io, events)
      end

      # Native Zig io_read/io_write use recv/send with kernel buffer
      # draining. Falls back to Ruby-level nonblock+io_wait for non-socket
      # fds (pipes, files) where native returns nil.

      EAGAIN = -Errno::EAGAIN::Errno
      EWOULDBLOCK = -Errno::EWOULDBLOCK::Errno

      # @param fiber [Fiber]
      # @param io [IO]
      # @param buffer [IO::Buffer]
      # @param length [Integer]
      # @param offset [Integer]
      # @return [Integer] bytes read, or negative errno
      def io_read(fiber, io, buffer, length, offset = 0)
        result = native_io_read(io.fileno, buffer, length, offset)
        return result unless result.nil?

        ruby_io_read(fiber, io, buffer, length, offset)
      end

      # @param fiber [Fiber]
      # @param io [IO]
      # @param buffer [IO::Buffer]
      # @param length [Integer]
      # @param offset [Integer]
      # @return [Integer] bytes written, or negative errno
      def io_write(fiber, io, buffer, length, offset = 0)
        result = native_io_write(io.fileno, buffer, length, offset)
        return result unless result.nil?

        ruby_io_write(fiber, io, buffer, length, offset)
      end

      # Cancel pending waiters and close the descriptor.
      # @param io [IO]
      def io_close(io)
        fd = io.respond_to?(:fileno) ? io.fileno : io.to_i
        super(fd, IOError.new("stream closed while waiting"))
      end

      # Wait for a child process on a background thread.
      # @param fiber [Fiber]
      # @param pid [Integer]
      # @param flags [Integer]
      # @return [Process::Status]
      def process_wait(fiber, pid, flags)
        Thread.new do
          Thread.current.report_on_exception = false
          Process::Status.wait(pid, flags)
        end.value
      end

      private

      def drain_auxiliary
        return if @auxiliary.empty?

        items = @auxiliary_mutex.synchronize do
          batch = @auxiliary.dup
          @auxiliary.clear
          batch
        end

        items.each { |item| item.transfer if item.alive? }
      end

      # Ruby-level io_read/io_write for non-socket fds (pipes, files).
      # Mirrors io-event's Select fallback selector.
      def ruby_io_read(fiber, io, buffer, length, offset = 0)
        total = 0

        IO::Event::Selector.nonblock(io) do
          while true
            result = Fiber.blocking { buffer.read(io, 0, offset) }

            if result < 0
              if result == EAGAIN || result == EWOULDBLOCK
                io_wait(fiber, io, IO::READABLE)
              else
                return result
              end
            elsif result == 0
              break
            else
              total += result
              break if total >= length
              offset += result
            end
          end
        end

        total
      end

      def ruby_io_write(fiber, io, buffer, length, offset = 0)
        total = 0

        IO::Event::Selector.nonblock(io) do
          while true
            result = Fiber.blocking { buffer.write(io, 0, offset) }

            if result < 0
              if result == EAGAIN || result == EWOULDBLOCK
                io_wait(fiber, io, IO::WRITABLE)
              else
                return result
              end
            elsif result == 0
              break
            else
              total += result
              break if total >= length
              offset += result
            end
          end
        end

        total
      end

      def fallback_io_wait(io, events)
        Thread.new do
          Thread.current.report_on_exception = false
          readers = (events & IO::READABLE).zero? ? nil : [io]
          writers = (events & IO::WRITABLE).zero? ? nil : [io]
          ready = ::IO.select(readers, writers, nil, nil)
          return false unless ready

          readiness = 0
          readiness |= IO::READABLE if ready[0]&.include?(io)
          readiness |= IO::WRITABLE if ready[1]&.include?(io)
          readiness.zero? ? false : readiness
        end.value
      end
    end

    # Register as the default IO::Event selector for Async.
    # Call after +require "async"+ so IO::Event::Selector is available.
    def self.default!
      IO::Event::Selector.const_set(:CarbonFiberSelector, CarbonFiber::Async::Selector) unless IO::Event::Selector.const_defined?(:CarbonFiberSelector, false)
      ENV["IO_EVENT_SELECTOR"] = "CarbonFiberSelector"
    end
  end
end
