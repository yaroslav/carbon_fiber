# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler, :unix_only do
  include_context "with scheduler"

  describe "waiting for child processes" do
    it "resumes the fiber once the child exits cleanly" do
      pid = fork { exit! 0 }
      status = nil

      Fiber.schedule { status = Process::Status.wait(pid) }
      scheduler.run

      expect(status).to be_success
    end

    it "captures a non-zero exit code" do
      pid = fork { exit! 42 }
      status = nil

      Fiber.schedule { status = Process::Status.wait(pid) }
      scheduler.run

      expect(status.exitstatus).to eq(42)
    end
  end
end
