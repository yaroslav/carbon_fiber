# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe CarbonFiber::Scheduler, :unix_only do
  include_context "with scheduler"

  describe "reading from a pipe" do
    it "wakes the reading fiber once a writer sends data" do
      reader, writer = IO.pipe
      received = nil

      Fiber.schedule { received = reader.gets }
      Fiber.schedule {
        writer.puts "hello"
        writer.close
      }

      scheduler.run
      expect(received).to eq("hello\n")
    ensure
      begin
        reader.close
      rescue
        nil
      end
      begin
        writer.close
      rescue
        nil
      end
    end

    it "lets two fibers each read from their own pipe concurrently" do
      pairs = Array.new(2) { IO.pipe }
      results = []

      pairs.each { |r, _| Fiber.schedule { results << r.gets } }
      pairs.each { |_, w|
        Fiber.schedule {
          w.puts "data"
          w.close
        }
      }

      scheduler.run
      expect(results).to all(eq("data\n"))
    ensure
      pairs.each { |r, w|
        begin
          r.close
        rescue
          nil
        end
        begin
          w.close
        rescue
          nil
        end
      }
    end
  end

  describe "writing to a pipe" do
    it "delivers data written in one fiber to another reading fiber" do
      reader, writer = IO.pipe
      sent = "payload"
      received = nil

      Fiber.schedule { received = reader.read(sent.bytesize) }
      Fiber.schedule {
        writer.write(sent)
        writer.close
      }

      scheduler.run
      expect(received).to eq(sent)
    ensure
      begin
        reader.close
      rescue
        nil
      end
      begin
        writer.close
      rescue
        nil
      end
    end
  end

  describe "closing an IO object with a pending reader" do
    it "unblocks the waiting fiber with an error" do
      reader, writer = IO.pipe
      raised = nil

      Fiber.schedule do
        reader.read(1)
      rescue IOError => e
        raised = e
      end

      Fiber.schedule { reader.close }

      scheduler.run
      expect(raised).to be_a(IOError)
    ensure
      begin
        writer.close
      rescue
        nil
      end
    end
  end

  # Ruby 4.1 (ruby/ruby#18793) hands fiber_interrupt an operation-scoped
  # Fiber::Scheduler::InterruptTarget instead of the fiber. This stand-in has
  # the same interface, so the path is covered on every Ruby.
  describe "an IO interrupt delivered through an operation proxy" do
    let(:proxy_class) do
      Struct.new(:fiber, :active) do
        def alive?
          active && fiber.alive?
        end

        def raise(exception)
          fiber.raise(exception) if active
        end
      end
    end

    it "raises the exception in the interrupted fiber" do
      parked = nil
      raised = nil

      # The timeout turns a lost interrupt into a failure instead of a hang.
      Fiber.schedule do
        parked = Fiber.current
        Fiber.scheduler.block(Object.new, 2)
      rescue IOError => e
        raised = e
      end

      Fiber.schedule do
        sleep 0 until parked
        Fiber.scheduler.fiber_interrupt(proxy_class.new(parked, true), IOError.new("stream closed"))
      end

      scheduler.run
      expect(raised).to be_a(IOError)
    end

    it "does nothing once the interrupted operation has finished" do
      blocker = Object.new
      parked = nil
      outcome = nil

      Fiber.schedule do
        parked = Fiber.current
        Fiber.scheduler.block(blocker, nil)
        outcome = :resumed
      rescue IOError
        outcome = :interrupted
      end

      Fiber.schedule do
        sleep 0 until parked
        Fiber.scheduler.fiber_interrupt(proxy_class.new(parked, false), IOError.new("stream closed"))
        Fiber.scheduler.unblock(blocker, parked)
      end

      scheduler.run
      expect(outcome).to eq(:resumed)
    end
  end

  describe "reading and writing regular files" do
    it "reads a file inside a fiber" do
      file = Tempfile.new("carbon_io")
      file.write("regular file contents")
      file.flush
      content = nil

      Fiber.schedule { content = File.read(file.path) }

      scheduler.run
      expect(content).to eq("regular file contents")
    ensure
      file.close!
    end

    it "writes a file inside a fiber" do
      file = Tempfile.new("carbon_io")

      Fiber.schedule { File.write(file.path, "written from a fiber") }

      scheduler.run
      expect(File.read(file.path)).to eq("written from a fiber")
    ensure
      file.close!
    end
  end
end
