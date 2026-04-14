# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "unblock called from a background thread" do
    it "resumes a parked fiber when a thread calls unblock" do
      # This is the pattern used by database drivers and job queues that
      # complete work off-thread and then wake up the waiting fiber.
      blocker = Object.new
      parked = nil
      result = nil

      Fiber.schedule do
        parked = Fiber.current
        scheduler.block(blocker, nil)
        result = :resumed
      end

      Thread.new do
        sleep 0 until parked
        scheduler.unblock(blocker, parked)
        scheduler.wakeup
      end

      scheduler.run
      expect(result).to eq(:resumed)
    end

    it "resumes multiple fibers unblocked by different threads" do
      blocker = Object.new
      parked = []
      results = []

      3.times do |i|
        Fiber.schedule do
          f = Fiber.current
          parked << f
          scheduler.block(blocker, nil)
          results << i
        end
      end

      Thread.new do
        sleep 0 until parked.size == 3
        parked.each do |f|
          scheduler.unblock(blocker, f)
        end
        scheduler.wakeup
      end

      scheduler.run
      expect(results).to contain_exactly(0, 1, 2)
    end
  end
end
