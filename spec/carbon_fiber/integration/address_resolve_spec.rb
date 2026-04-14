# frozen_string_literal: true

require "spec_helper"
require "resolv"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "resolving hostnames" do
    it "returns addresses for localhost" do
      result = nil
      Fiber.schedule { result = Resolv.getaddresses("localhost") }
      scheduler.run
      expect(result).to be_an(Array)
      expect(result).not_to be_empty
    end

    it "handles an IPv6 zone ID suffix without erroring" do
      result = nil
      Fiber.schedule { result = Resolv.getaddresses("localhost%lo0") }
      scheduler.run
      expect(result).to be_an(Array)
    end
  end
end
