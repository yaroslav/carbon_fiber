# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "fiber-aware timeouts" do
    describe "exceeding the time limit" do
      it "raises Timeout::Error in the fiber" do
        raised = nil

        Fiber.schedule do
          Timeout.timeout(0.02) { sleep 10 }
        rescue Timeout::Error => e
          raised = e
        end

        scheduler.run
        expect(raised).to be_a(Timeout::Error)
      end

      it "supports a custom exception class" do
        raised = nil

        Fiber.schedule do
          Timeout.timeout(0.02, RuntimeError, "too slow") { sleep 10 }
        rescue RuntimeError => e
          raised = e
        end

        scheduler.run
        expect(raised).to be_a(RuntimeError)
        expect(raised.message).to eq("too slow")
      end
    end

    describe "finishing before the time limit" do
      it "does not raise and returns the block value" do
        result = nil
        raised = nil

        Fiber.schedule do
          result = Timeout.timeout(1.0) {
            sleep 0.01
            :done
          }
        rescue Timeout::Error => e
          raised = e
        end

        scheduler.run
        expect(raised).to be_nil
        expect(result).to eq(:done)
      end
    end
  end
end
