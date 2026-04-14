# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "concurrently blocking fibers" do
    describe "sharing a Queue across fibers" do
      it "wakes the consumer once the producer pushes an item" do
        queue = Queue.new
        received = nil

        Fiber.schedule { received = queue.pop }
        Fiber.schedule { queue.push(:hello) }

        scheduler.run
        expect(received).to eq(:hello)
      end

      it "handles multiple producers and consumers in FIFO order" do
        queue = Queue.new
        results = []

        3.times { |i| Fiber.schedule { queue.push(i) } }
        3.times { Fiber.schedule { results << queue.pop } }

        scheduler.run
        expect(results).to eq([0, 1, 2])
      end
    end

    describe "sharing a Mutex across fibers" do
      it "lets two fibers acquire the lock without deadlocking" do
        mutex = Mutex.new
        order = []

        Fiber.schedule { mutex.synchronize { order << :a } }
        Fiber.schedule { mutex.synchronize { order << :b } }

        scheduler.run
        expect(order).to contain_exactly(:a, :b)
      end
    end

    describe "running a blocking operation in a background thread" do
      it "returns the computed value to the scheduled fiber" do
        result = nil
        Fiber.schedule { result = File.read(File::NULL) }
        scheduler.run
        expect(result).to eq("")
      end

      it "propagates an exception from the background work to the fiber" do
        raised = nil
        Fiber.schedule do
          File.read("/this/path/does/not/exist/hopefully")
        rescue Errno::ENOENT => e
          raised = e
        end
        scheduler.run
        expect(raised).to be_a(Errno::ENOENT)
      end
    end
  end
end
