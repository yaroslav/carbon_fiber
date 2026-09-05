# frozen_string_literal: true

require "spec_helper"

# Ractor.new warns once per process; the examples below create dozens.
Warning[:experimental] = false

# A fiber scheduler is per thread and every Ractor has its own threads, so
# each Ractor installs its own CarbonFiber::Scheduler. A Ractor block cannot
# reach the example's self or locals, so the workload lives on a module.
module RactorSchedulerWorkload
  module_function

  # Installs a scheduler on the calling thread and runs +iterations+ rounds
  # of the hooks a worker needs: kernel_sleep, io_wait on a pipe,
  # block/unblock through a Thread::Queue, and timeout_after. Returns one
  # sorted event list per round so runs can be compared across Ractors.
  def run(iterations)
    scheduler = CarbonFiber::Scheduler.new
    Fiber.set_scheduler(scheduler)

    Array.new(iterations) do
      events = []

      Fiber.schedule do
        sleep 0.002
        events << :slept
      end

      reader, writer = IO.pipe
      Fiber.schedule { events << [:read, reader.read(3)] }
      Fiber.schedule do
        sleep 0.001
        writer.write("abc")
        writer.close
      end

      queue = Thread::Queue.new
      Fiber.schedule { events << [:popped, queue.pop] }
      Fiber.schedule { queue.push(:item) }

      Fiber.schedule do
        Timeout.timeout(0.002) { sleep 1 }
      rescue Timeout::Error
        events << :timed_out
      end

      scheduler.run
      reader.close
      events.sort_by(&:to_s)
    end
  ensure
    Fiber.set_scheduler(nil)
  end

  # Ruby 3.4 reads a Ractor's result with #take, Ruby 4.0 with #value.
  def result_of(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end
end

RSpec.describe "CarbonFiber::Scheduler inside a Ractor" do
  # Canary for the rb_ext_ractor_safe declaration in Init: without it,
  # every native method raises Ractor::UnsafeError from a non-main Ractor.
  it "constructs a scheduler without Ractor::UnsafeError" do
    outcome = RactorSchedulerWorkload.result_of(Ractor.new do
      CarbonFiber::Scheduler.new.close
      :constructed
    rescue Ractor::UnsafeError => e
      e.message
    end)

    expect(outcome).to eq(:constructed)
  end

  it "runs sleep, io_wait, block/unblock, and timeout_after like the main Ractor" do
    expected = RactorSchedulerWorkload.run(1)
    actual = RactorSchedulerWorkload.result_of(Ractor.new { RactorSchedulerWorkload.run(1) })

    expect(expected.first).to eq([[:popped, :item], [:read, "abc"], :slept, :timed_out])
    expect(actual).to eq(expected)
  end

  it "runs four Ractors, each with its own scheduler, for 100 rounds" do
    # Ruby 3.4 aborts or hangs when several Ractors drive fiber schedulers at
    # once, with the pure-Ruby selector as much as the native one; Ruby 4.0
    # reworked Ractor threading and runs this reliably.
    skip "several Ractors with schedulers need Ruby 4.0 or later" if RUBY_VERSION < "4.0"

    expected = RactorSchedulerWorkload.run(1).first
    ractors = Array.new(4) { Ractor.new { RactorSchedulerWorkload.run(100) } }
    results = ractors.map { |ractor| RactorSchedulerWorkload.result_of(ractor) }

    expect(results.map(&:size)).to eq([100, 100, 100, 100])
    expect(results.flatten(1)).to all(eq(expected))
  end
end
