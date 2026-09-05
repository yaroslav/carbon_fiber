# frozen_string_literal: true

require "spec_helper"
require "io/event"
require "carbon_fiber/async"
require "socket"
require "io/nonblock"
require_relative "../support/fake_v4_buffer"

# Async::Selector v4 hooks: the io-event-compatible adapter under the
# Ruby 4.1+ single-transfer contract. Native socket paths reorder the
# public (offset, length) into the stable native ABI; the Ruby fallback
# makes exactly one buffer attempt and never calls io_wait.
RSpec.describe "CarbonFiber::Async::Selector v4 hooks" do
  eagain = -Errno::EAGAIN::Errno

  let(:selector) { CarbonFiber::Async::Selector.new(Fiber.current, io_contract_v4: true) }

  after do
    begin
      selector.close
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

  it "accepts the io_contract_v4 keyword" do
    expect(selector).to be_a(CarbonFiber::Async::Selector)
  end

  it "defaults the keyword to the running Ruby's contract" do
    default_selector = CarbonFiber::Async::Selector.new(Fiber.current)
    default_selector.close
  end

  describe "native socket path", :native_only do
    it "returns 0 for a zero-length read without consuming data" do
      local, peer = stream_pair
      peer.write("hello")
      buffer = IO::Buffer.new(16)

      expect(selector.io_read_v4(Fiber.current, local, buffer, 0, 0)).to eq(0)
      expect(selector.io_read_v4(Fiber.current, local, buffer, 0, 5)).to eq(5)
      expect(buffer.get_string(0, 5)).to eq("hello")
    end

    it "passes offset and length through in the v4 order" do
      local, peer = stream_pair
      peer.write("hello")
      buffer = IO::Buffer.new(16)

      expect(selector.io_read_v4(Fiber.current, local, buffer, 4, 5)).to eq(5)
      expect(buffer.get_string(4, 5)).to eq("hello")
    end

    it "returns -EAGAIN for an empty socket" do
      local, _peer = stream_pair
      buffer = IO::Buffer.new(16)

      expect(selector.io_read_v4(Fiber.current, local, buffer, 0, 16)).to eq(eagain)
    end

    it "writes the requested slice from the buffer offset" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(9)
      buffer.set_string("XXhelloXX")

      expect(selector.io_write_v4(Fiber.current, local, buffer, 2, 5)).to eq(5)
      expect(peer.read(5)).to eq("hello")
    end

    it "returns 0 for a zero-length write without sending" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(16)
      buffer.set_string("junk")

      expect(selector.io_write_v4(Fiber.current, local, buffer, 0, 0)).to eq(0)
      peer.nonblock = true
      expect { peer.read_nonblock(1) }.to raise_error(IO::WaitReadable)
    end
  end

  describe "ruby fallback (single transfer)" do
    def pipe_pair
      reader, writer = IO.pipe
      @ios ||= []
      @ios.concat([reader, writer])
      [reader, writer]
    end

    it "makes exactly one read attempt in the v4 argument order" do
      reader, _writer = pipe_pair
      buffer = FakeV4Buffer.new(7)

      result = selector.__send__(:ruby_io_read_v4, reader, buffer, 2, 5)

      expect(result).to eq(7)
      expect(buffer.calls).to eq([[:read, reader, 2, 5]])
    end

    it "passes -EAGAIN through from a read without waiting or retrying" do
      reader, _writer = pipe_pair
      buffer = FakeV4Buffer.new(eagain)

      result = selector.__send__(:ruby_io_read_v4, reader, buffer, 0, 16)

      expect(result).to eq(eagain)
      expect(buffer.calls.length).to eq(1)
    end

    it "returns a short read without looping toward the requested length" do
      reader, _writer = pipe_pair
      buffer = FakeV4Buffer.new(3)

      result = selector.__send__(:ruby_io_read_v4, reader, buffer, 0, 100)

      expect(result).to eq(3)
      expect(buffer.calls.length).to eq(1)
    end

    it "makes exactly one write attempt in the v4 argument order" do
      _reader, writer = pipe_pair
      buffer = FakeV4Buffer.new(5)

      result = selector.__send__(:ruby_io_write_v4, writer, buffer, 2, 5)

      expect(result).to eq(5)
      expect(buffer.calls).to eq([[:write, writer, 2, 5]])
    end

    it "returns a short write without looping toward the requested length" do
      _reader, writer = pipe_pair
      buffer = FakeV4Buffer.new(3)

      result = selector.__send__(:ruby_io_write_v4, writer, buffer, 0, 100)

      expect(result).to eq(3)
      expect(buffer.calls.length).to eq(1)
    end
  end

  describe "zero-length requests" do
    it "returns 0 from io_read_v4 before touching the io" do
      buffer = FakeV4Buffer.new
      not_an_io = Object.new

      expect(selector.io_read_v4(Fiber.current, not_an_io, buffer, 0, 0)).to eq(0)
      expect(buffer.calls).to be_empty
    end

    it "returns 0 from io_write_v4 before touching the io" do
      buffer = FakeV4Buffer.new
      not_an_io = Object.new

      expect(selector.io_write_v4(Fiber.current, not_an_io, buffer, 0, 0)).to eq(0)
      expect(buffer.calls).to be_empty
    end
  end
end
