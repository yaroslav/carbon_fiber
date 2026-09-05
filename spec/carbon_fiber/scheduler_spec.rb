# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  subject(:scheduler) { described_class.new }

  after {
    begin
      scheduler.close
    rescue
      nil
    end
  }

  describe "tracking lifecycle state" do
    it "starts open" do
      expect(scheduler.closed?).to be false
    end

    it "becomes closed after closing" do
      scheduler.close
      expect(scheduler.closed?).to be true
    end

    it "tolerates being closed more than once" do
      scheduler.close
      expect { scheduler.close }.not_to raise_error
    end
  end

  describe "waiting for background work" do
    # A fiber parked on a background thread leaves nothing in the ready
    # list, timers, or read waits, and the loop must sleep until that
    # thread resumes it rather than poll: polling burns the whole wait on
    # CPU, and inside a non-main Ractor it starves the very thread it is
    # waiting for.
    it "sleeps instead of spinning while a fiber waits on a background thread" do
      Fiber.set_scheduler(scheduler)
      result = nil
      Fiber.schedule do
        result = scheduler.blocking_operation_wait(lambda {
          sleep 0.3
          :done
        })
      end

      before = Process.times
      scheduler.run
      after = Process.times

      cpu = (after.utime - before.utime) + (after.stime - before.stime)
      expect(result).to eq(:done)
      expect(cpu).to be < 0.15
    ensure
      Fiber.set_scheduler(nil)
    end
  end

  describe "reading the current time" do
    it "returns a monotonic float" do
      expect(scheduler.current_time).to be_a(Float)
    end

    it "never goes backwards" do
      t1 = scheduler.current_time
      t2 = scheduler.current_time
      expect(t2).to be >= t1
    end
  end
end
