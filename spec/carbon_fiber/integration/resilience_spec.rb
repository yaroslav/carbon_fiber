# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "resilience" do
    describe "an exception inside one fiber" do
      it "does not prevent other fibers from completing" do
        results = []

        Fiber.schedule do
          raise "boom"
        rescue RuntimeError
          results << :rescued
        end

        Fiber.schedule {
          sleep 0.01
          results << :other
        }

        scheduler.run
        expect(results).to contain_exactly(:rescued, :other)
      end

      it "can be caught and the fiber continues normally" do
        result = nil

        Fiber.schedule do
          raise ArgumentError, "oops"
        rescue ArgumentError
          sleep 0.01
          result = :recovered
        end

        scheduler.run
        expect(result).to eq(:recovered)
      end
    end

    describe "interrupting a sleeping fiber from another fiber" do
      it "delivers the exception to the sleeping fiber" do
        raised = nil

        victim = Fiber.schedule do
          sleep 10
        rescue RuntimeError => e
          raised = e
        end

        Fiber.schedule { victim.raise(RuntimeError, "stop") }

        scheduler.run
        expect(raised).to be_a(RuntimeError)
        expect(raised.message).to eq("stop")
      end
    end

    describe "each thread running its own independent scheduler" do
      it "isolates fibers between threads" do
        thread_results = {}

        threads = 2.times.map do |i|
          Thread.new do
            sched = CarbonFiber::Scheduler.new
            Fiber.set_scheduler(sched)

            results = []
            Fiber.schedule {
              sleep 0.01
              results << i
            }
            sched.run

            thread_results[i] = results
          ensure
            Fiber.set_scheduler(nil) if Fiber.scheduler == sched
          end
        end

        threads.each(&:join)

        expect(thread_results[0]).to eq([0])
        expect(thread_results[1]).to eq([1])
      end
    end

    describe "closing the scheduler while fibers are still pending" do
      it "drains all pending work before marking closed" do
        completed = false

        Fiber.schedule {
          sleep 0.01
          completed = true
        }

        scheduler.close
        expect(completed).to be true
        expect(scheduler.closed?).to be true
      end
    end
  end
end
