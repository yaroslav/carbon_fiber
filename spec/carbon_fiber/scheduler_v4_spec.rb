# frozen_string_literal: true

require "spec_helper"
require "socket"
require "io/nonblock"
require_relative "../support/fake_v4_buffer"

# Scheduler#io_read_v4 / #io_write_v4: the Ruby 4.1+ hook bodies. The public
# (offset, length) order is reordered into the native selector's stable
# (length, offset) ABI, and the background fallback makes exactly one
# buffer.read/buffer.write attempt in the new IO::Buffer range order.
RSpec.describe "CarbonFiber::Scheduler v4 hooks" do
  eagain = -Errno::EAGAIN::Errno

  it "accepts the io_contract_v4 keyword" do
    scheduler = CarbonFiber::Scheduler.new(io_contract_v4: true)
    scheduler.close
  end

  it "defaults the keyword to the running Ruby's contract" do
    scheduler = CarbonFiber::Scheduler.new
    scheduler.close
  end

  describe "native socket path", :native_only do
    subject(:scheduler) { CarbonFiber::Scheduler.new(io_contract_v4: true) }

    after do
      begin
        scheduler.close
      rescue
        nil
      end
      @ios&.each { |io|
        begin
          io.close
        rescue
          nil
        end
      }
    end

    def stream_pair
      pair = UNIXSocket.pair
      @ios ||= []
      @ios.concat(pair)
      pair
    end

    it "returns 0 for a zero-length read without consuming data" do
      local, peer = stream_pair
      peer.write("hello")
      buffer = IO::Buffer.new(16)

      expect(scheduler.io_read_v4(local, buffer, 0, 0)).to eq(0)
      expect(scheduler.io_read_v4(local, buffer, 0, 5)).to eq(5)
      expect(buffer.get_string(0, 5)).to eq("hello")
    end

    it "passes offset and length through in the v4 order" do
      local, peer = stream_pair
      peer.write("hello")
      buffer = IO::Buffer.new(16)

      expect(scheduler.io_read_v4(local, buffer, 4, 5)).to eq(5)
      expect(buffer.get_string(4, 5)).to eq("hello")
    end

    it "returns -EAGAIN for an empty socket" do
      local, _peer = stream_pair
      buffer = IO::Buffer.new(16)

      expect(scheduler.io_read_v4(local, buffer, 0, 16)).to eq(eagain)
    end

    it "writes the requested slice from the buffer offset" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(9)
      buffer.set_string("XXhelloXX")

      expect(scheduler.io_write_v4(local, buffer, 2, 5)).to eq(5)
      expect(peer.read(5)).to eq("hello")
    end

    it "returns 0 for a zero-length write without sending" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(16)
      buffer.set_string("junk")

      expect(scheduler.io_write_v4(local, buffer, 0, 0)).to eq(0)
      peer.nonblock = true
      expect { peer.read_nonblock(1) }.to raise_error(IO::WaitReadable)
    end
  end

  describe "background fallback path" do
    let(:scheduler) { CarbonFiber::Scheduler.new(io_contract_v4: true) }
    let(:fake_io) { Object.new }

    before { Fiber.set_scheduler(scheduler) }

    after do
      Fiber.set_scheduler(nil) if Fiber.scheduler == scheduler
      begin
        scheduler.close
      rescue
        nil
      end
    end

    it "makes exactly one read attempt in the v4 argument order" do
      buffer = FakeV4Buffer.new(42)
      result = nil

      Fiber.schedule { result = scheduler.io_read_v4(fake_io, buffer, 2, 5) }
      scheduler.run

      expect(result).to eq(42)
      expect(buffer.calls).to eq([[:read, fake_io, 2, 5]])
    end

    it "passes -EAGAIN through from a read without retrying" do
      buffer = FakeV4Buffer.new(eagain)
      result = nil

      Fiber.schedule { result = scheduler.io_read_v4(fake_io, buffer, 0, 16) }
      scheduler.run

      expect(result).to eq(eagain)
      expect(buffer.calls.length).to eq(1)
    end

    it "makes exactly one write attempt in the v4 argument order" do
      buffer = FakeV4Buffer.new(5)
      result = nil

      Fiber.schedule { result = scheduler.io_write_v4(fake_io, buffer, 2, 5) }
      scheduler.run

      expect(result).to eq(5)
      expect(buffer.calls).to eq([[:write, fake_io, 2, 5]])
    end

    it "passes a short write through without retrying" do
      buffer = FakeV4Buffer.new(3)
      result = nil

      Fiber.schedule { result = scheduler.io_write_v4(fake_io, buffer, 0, 10) }
      scheduler.run

      expect(result).to eq(3)
      expect(buffer.calls.length).to eq(1)
    end

    it "returns 0 for a zero-length read without touching the buffer" do
      buffer = FakeV4Buffer.new
      result = nil

      Fiber.schedule { result = scheduler.io_read_v4(fake_io, buffer, 0, 0) }
      scheduler.run

      expect(result).to eq(0)
      expect(buffer.calls).to be_empty
    end
  end
end
