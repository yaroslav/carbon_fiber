# frozen_string_literal: true

require "spec_helper"

# Tests the pure-Ruby fallback selector (FALLBACK_SELECTOR_CLASS is captured in
# spec_helper.rb before the native extension loads, so this never mutates global
# state regardless of test ordering).
RSpec.describe CarbonFiber::Scheduler, "using the pure-Ruby fallback selector" do
  let(:scheduler) { CarbonFiber::Scheduler.new(selector: FALLBACK_SELECTOR_CLASS) }

  before { Fiber.set_scheduler(scheduler) }

  after do
    Fiber.set_scheduler(nil) if Fiber.scheduler == scheduler
    begin
      scheduler.close
    rescue
      nil
    end
  end

  it "runs concurrent sleeps to completion" do
    order = []
    Fiber.schedule {
      sleep 0.010
      order << :slow
    }
    Fiber.schedule {
      sleep 0.001
      order << :fast
    }
    scheduler.run
    expect(order).to eq([:fast, :slow])
  end

  it "reads and writes through a pipe", :unix_only do
    r, w = IO.pipe
    received = nil
    Fiber.schedule {
      received = r.read(5)
      r.close
    }
    Fiber.schedule {
      w.write("hello")
      w.close
    }
    scheduler.run
    expect(received).to eq("hello")
  end

  it "propagates exceptions without affecting sibling fibers" do
    results = []
    Fiber.schedule {
      begin
        raise "boom"
      rescue
        nil
      end
      results << :survived
    }
    Fiber.schedule { results << :sibling }
    scheduler.run
    expect(results).to contain_exactly(:survived, :sibling)
  end

  it "honours Timeout::Error inside a fiber" do
    raised = nil
    Fiber.schedule do
      Timeout.timeout(0.020) { sleep 1 }
    rescue Timeout::Error => e
      raised = e
    end
    scheduler.run
    expect(raised).to be_a(Timeout::Error)
  end

  it "resumes a fiber blocked on a custom object when unblocked" do
    blocker = Object.new
    parked = nil
    result = nil
    Fiber.schedule do
      parked = Fiber.current
      Fiber.scheduler.block(blocker, nil)
      result = :resumed
    end
    Fiber.schedule do
      sleep 0 until parked
      Fiber.scheduler.unblock(blocker, parked)
    end
    scheduler.run
    expect(result).to eq(:resumed)
  end
end
