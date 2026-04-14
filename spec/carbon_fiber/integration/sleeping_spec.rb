# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "sleeping fibers" do
    it "runs two sleeps concurrently without blocking the thread" do
      results = []
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Fiber.schedule {
        sleep 0.01
        results << :a
      }
      Fiber.schedule {
        sleep 0.02
        results << :b
      }

      scheduler.run

      expect(results).to eq([:a, :b])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 0.15
    end

    it "completes a zero-duration sleep without hanging" do
      done = false
      Fiber.schedule {
        sleep 0
        done = true
      }
      scheduler.run
      expect(done).to be true
    end

    it "runs many fibers with staggered delays in the right order" do
      results = []
      [0.03, 0.01, 0.02].each_with_index do |delay, i|
        Fiber.schedule {
          sleep delay
          results << i
        }
      end
      scheduler.run
      expect(results).to eq([1, 2, 0])
    end
  end
end
