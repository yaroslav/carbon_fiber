# frozen_string_literal: true

require "spec_helper"

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
end
