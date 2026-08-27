# frozen_string_literal: true

require "spec_helper"
require "socket"
require "io/nonblock"

# Native selector semantics under the Ruby 4.1+ single-transfer contract
# (selector.io_contract_v4 = true). The native ABI keeps its
# (fd, buffer, length, offset) argument order on both contracts; the Ruby
# wrappers do the reordering. In v4 mode the native paths never suspend,
# so every call here is safe outside a running scheduler.
RSpec.describe "native selector v4 contract", :native_only do
  let(:eagain) { -Errno::EAGAIN::Errno }
  let(:einval) { -Errno::EINVAL::Errno }

  let(:selector) { CarbonFiber::Native::Selector.new(Fiber.current) }

  after do
    selector.destroy
  rescue
    nil
  end

  def v4_selector
    selector.io_contract_v4 = true
    selector
  end

  def stream_pair
    pair = UNIXSocket.pair
    @ios ||= []
    @ios.concat(pair)
    pair
  end

  after {
    @ios&.each { |io|
      begin
        io.close
      rescue
        nil
      end
    }
  }

  describe "io_contract_v4=" do
    it "accepts a boolean" do
      expect(selector.io_contract_v4 = true).to be true
    end
  end

  describe "single-transfer reads" do
    it "returns 0 for a zero-length read without consuming data" do
      local, peer = stream_pair
      peer.write("hello")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 0, 0)).to eq(0)
      expect(v4_selector.io_read(local.fileno, buffer, 5, 0)).to eq(5)
      expect(buffer.get_string(0, 5)).to eq("hello")
    end

    it "returns -EAGAIN immediately when no data is available" do
      local, _peer = stream_pair
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 16, 0)).to eq(eagain)
    end

    it "reads at most length bytes and leaves the rest queued" do
      local, peer = stream_pair
      peer.write("abcdefgh")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 4, 0)).to eq(4)
      expect(buffer.get_string(0, 4)).to eq("abcd")
      expect(v4_selector.io_read(local.fileno, buffer, 16, 0)).to eq(4)
      expect(buffer.get_string(0, 4)).to eq("efgh")
    end

    it "returns a short result when less than length is available" do
      local, peer = stream_pair
      peer.write("abc")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 16, 0)).to eq(3)
    end

    it "writes into the buffer at the requested offset" do
      local, peer = stream_pair
      peer.write("hello")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 5, 4)).to eq(5)
      expect(buffer.get_string(4, 5)).to eq("hello")
    end

    it "returns 0 at EOF" do
      local, peer = stream_pair
      peer.close
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 16, 0)).to eq(0)
    end

    it "returns -EINVAL when offset exceeds the buffer capacity" do
      local, _peer = stream_pair
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 4, 32)).to eq(einval)
    end

    it "clamps length to the buffer capacity after offset" do
      local, peer = stream_pair
      peer.write("abcdefghij")
      buffer = IO::Buffer.new(8)

      expect(v4_selector.io_read(local.fileno, buffer, 100, 4)).to eq(4)
      expect(buffer.get_string(4, 4)).to eq("abcd")
      expect(v4_selector.io_read(local.fileno, buffer, 8, 0)).to eq(6)
      expect(buffer.get_string(0, 6)).to eq("efghij")
    end

    it "consumes only one datagram per call" do
      local, peer = Socket.pair(:UNIX, :DGRAM, 0)
      @ios ||= []
      @ios.concat([local, peer])
      peer.write("aaa")
      peer.write("bbbbb")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(local.fileno, buffer, 16, 0)).to eq(3)
      expect(buffer.get_string(0, 3)).to eq("aaa")
      expect(v4_selector.io_read(local.fileno, buffer, 16, 0)).to eq(5)
      expect(buffer.get_string(0, 5)).to eq("bbbbb")
    end

    it "reads from a pipe" do
      reader, writer = IO.pipe
      @ios ||= []
      @ios.concat([reader, writer])
      reader.nonblock = true
      writer.write("pipe!")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(reader.fileno, buffer, 16, 0)).to eq(5)
      expect(buffer.get_string(0, 5)).to eq("pipe!")
    end

    it "returns -EAGAIN for an empty pipe instead of deferring to Ruby" do
      reader, writer = IO.pipe
      @ios ||= []
      @ios.concat([reader, writer])
      reader.nonblock = true
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read(reader.fileno, buffer, 16, 0)).to eq(eagain)
    end

    it "supports the io_read_object entry point" do
      local, peer = stream_pair
      peer.write("object")
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_read_object(local, buffer, 6, 0)).to eq(6)
      expect(buffer.get_string(0, 6)).to eq("object")
    end
  end

  describe "single-transfer writes" do
    it "returns 0 for a zero-length write without sending" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(16)
      buffer.set_string("junk")

      expect(v4_selector.io_write(local.fileno, buffer, 0, 0)).to eq(0)
      peer.nonblock = true
      expect { peer.read_nonblock(1) }.to raise_error(IO::WaitReadable)
    end

    it "sends the requested slice from the buffer offset" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(9)
      buffer.set_string("XXhelloXX")

      expect(v4_selector.io_write(local.fileno, buffer, 5, 2)).to eq(5)
      expect(peer.read(5)).to eq("hello")
    end

    it "returns -EINVAL when offset exceeds the buffer capacity" do
      local, _peer = stream_pair
      buffer = IO::Buffer.new(16)

      expect(v4_selector.io_write(local.fileno, buffer, 4, 32)).to eq(einval)
    end

    it "returns -EAGAIN immediately when the kernel send buffer is full" do
      local, _peer = stream_pair
      local.nonblock = true
      chunk = "x" * 65_536
      1024.times do
        local.write_nonblock(chunk)
      rescue IO::WaitWritable
        break
      end
      buffer = IO::Buffer.new(16)
      buffer.set_string("more data pleas!")

      expect(v4_selector.io_write(local.fileno, buffer, 16, 0)).to eq(eagain)
    end

    it "writes to a pipe" do
      reader, writer = IO.pipe
      @ios ||= []
      @ios.concat([reader, writer])
      writer.nonblock = true
      buffer = IO::Buffer.new(5)
      buffer.set_string("pipe!")

      expect(v4_selector.io_write(writer.fileno, buffer, 5, 0)).to eq(5)
      expect(reader.read(5)).to eq("pipe!")
    end

    it "returns -EAGAIN for a full pipe instead of deferring to Ruby" do
      reader, writer = IO.pipe
      @ios ||= []
      @ios.concat([reader, writer])
      writer.nonblock = true
      chunk = "x" * 65_536
      1024.times do
        writer.write_nonblock(chunk)
      rescue IO::WaitWritable
        break
      end
      buffer = IO::Buffer.new(16)
      buffer.set_string("wont fit either!")

      expect(v4_selector.io_write(writer.fileno, buffer, 16, 0)).to eq(eagain)
    end

    it "supports the io_write_object entry point" do
      local, peer = stream_pair
      buffer = IO::Buffer.new(6)
      buffer.set_string("object")

      expect(v4_selector.io_write_object(local, buffer, 6, 0)).to eq(6)
      expect(peer.read(6)).to eq("object")
    end
  end

  describe "legacy contract remains the default" do
    it "treats a zero-length read as read-whatever-is-available" do
      local, peer = stream_pair
      peer.write("hi")
      buffer = IO::Buffer.new(16)

      expect(selector.io_read(local.fileno, buffer, 0, 0)).to eq(2)
    end

    it "defers an empty nonblocking pipe read to the Ruby fallback" do
      reader, writer = IO.pipe
      @ios ||= []
      @ios.concat([reader, writer])
      reader.nonblock = true
      buffer = IO::Buffer.new(16)

      expect(selector.io_read(reader.fileno, buffer, 16, 0)).to be_nil
    end

    it "drains across datagram boundaries" do
      local, peer = Socket.pair(:UNIX, :DGRAM, 0)
      @ios ||= []
      @ios.concat([local, peer])
      peer.write("aaa")
      peer.write("bbbbb")
      buffer = IO::Buffer.new(8)

      expect(selector.io_read(local.fileno, buffer, 8, 0)).to eq(8)
      expect(buffer.get_string(0, 8)).to eq("aaabbbbb")
    end
  end
end
