# frozen_string_literal: true

require "spec_helper"
require "socket"

# Drives the v4 hooks the way Ruby 4.1's buffered I/O loop does: one
# single-transfer attempt, io_wait on -EAGAIN, repeat until the request
# completes. Proves that short transfers compose into large ones across
# many hook invocations, which no per-call spec can show. Ruby 4.0 can't
# exercise this through IO#read (its caller speaks the legacy contract),
# so the caller loop is simulated here.
#
# The peer side runs on plain threads with blocking I/O, never through
# the scheduler: with the selector flipped to v4 on a v3 Ruby, ordinary
# IO calls inside scheduled fibers would cross contract generations
# (public v3 hooks over v4 native semantics), which production never does.
RSpec.describe "v4 single-transfer composition", :native_only do
  let(:eagain) { -Errno::EAGAIN::Errno }
  let(:scheduler) { CarbonFiber::Scheduler.new(io_contract_v4: true) }

  before { Fiber.set_scheduler(scheduler) }

  after do
    Fiber.set_scheduler(nil) if Fiber.scheduler == scheduler
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

  # Mirror of CRuby 4.1's buffered read loop over the v4 hook.
  def v4_read_exact(io, buffer, total)
    offset = 0
    stats = {invocations: 0, eagains: 0}

    while offset < total
      raise "composition did not converge" if stats[:invocations] > 100_000

      result = scheduler.io_read_v4(io, buffer, offset, total - offset)
      stats[:invocations] += 1

      if result == eagain
        stats[:eagains] += 1
        scheduler.io_wait(io, IO::READABLE, nil)
      elsif result.zero?
        break
      elsif result.negative?
        raise "io_read_v4 returned errno #{result}"
      else
        offset += result
      end
    end

    [offset, stats]
  end

  # Mirror of CRuby 4.1's buffered write loop over the v4 hook.
  def v4_write_exact(io, buffer, total)
    offset = 0
    stats = {invocations: 0, eagains: 0}

    while offset < total
      raise "composition did not converge" if stats[:invocations] > 100_000

      result = scheduler.io_write_v4(io, buffer, offset, total - offset)
      stats[:invocations] += 1

      if result == eagain
        stats[:eagains] += 1
        scheduler.io_wait(io, IO::WRITABLE, nil)
      elsif result.negative?
        raise "io_write_v4 returned errno #{result}"
      else
        offset += result
      end
    end

    [offset, stats]
  end

  it "completes a large read across many single-transfer invocations" do
    local, peer = stream_pair
    total = 256 * 1024
    payload = Random.new(42).bytes(total)
    buffer = IO::Buffer.new(total)
    received = nil
    stats = nil

    # Head start for the reader fiber so its first attempt provably hits an
    # empty socket and takes the -EAGAIN io_wait path at least once.
    writer = Thread.new do
      sleep(0.005)
      offset = 0
      while offset < total
        peer.write(payload.byteslice(offset, 32 * 1024))
        offset += 32 * 1024
        sleep(0.001)
      end
    end

    Fiber.schedule { received, stats = v4_read_exact(local, buffer, total) }
    scheduler.run
    writer.join

    expect(received).to eq(total)
    expect(buffer.get_string(0, total)).to eq(payload)
    expect(stats[:invocations]).to be > 1
    expect(stats[:eagains]).to be >= 1
  end

  it "completes a large write across many single-transfer invocations" do
    local, peer = stream_pair
    total = 256 * 1024
    payload = Random.new(7).bytes(total)
    buffer = IO::Buffer.new(total)
    buffer.set_string(payload)
    sent = nil
    stats = nil
    drained = +"".b

    # The socketpair send buffer is far smaller than the payload, and the
    # drain thread starts late and paces itself, so the driver must observe
    # short writes and -EAGAIN before the peer catches up.
    reader = Thread.new do
      sleep(0.005)
      while drained.bytesize < total
        drained << peer.readpartial(16 * 1024)
        sleep(0.001)
      end
    end

    Fiber.schedule { sent, stats = v4_write_exact(local, buffer, total) }
    scheduler.run
    reader.join

    expect(sent).to eq(total)
    expect(drained).to eq(payload)
    expect(stats[:invocations]).to be > 1
    expect(stats[:eagains]).to be >= 1
  end

  it "interleaves reads at advancing offsets without corrupting earlier data" do
    local, peer = stream_pair
    total = 64 * 1024
    payload = Random.new(3).bytes(total)
    buffer = IO::Buffer.new(total)
    received = nil
    stats = nil

    # Tiny uneven chunks force many partial transfers at odd offsets.
    writer = Thread.new do
      sleep(0.005)
      offset = 0
      chunk_sizes = [1, 7, 1024, 3, 4096, 511].cycle
      while offset < total
        size = [chunk_sizes.next, total - offset].min
        peer.write(payload.byteslice(offset, size))
        offset += size
        sleep(0.0005) if (offset % 8192) < 512
      end
    end

    Fiber.schedule { received, stats = v4_read_exact(local, buffer, total) }
    scheduler.run
    writer.join

    expect(received).to eq(total)
    expect(buffer.get_string(0, total)).to eq(payload)
    expect(stats[:invocations]).to be > 1
  end
end
