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
