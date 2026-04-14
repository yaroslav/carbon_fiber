# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "block and unblock scheduler primitives" do
    describe "a fiber waiting on a custom blocker" do
      it "resumes the waiting fiber when another fiber calls unblock" do
        blocker = Object.new
        parked = nil
        order = []

        Fiber.schedule do
          order << :before_block
          parked = Fiber.current
          Fiber.scheduler.block(blocker, nil)
          order << :resumed
        end

        Fiber.schedule do
          sleep 0 until parked
          order << :unblocking
          Fiber.scheduler.unblock(blocker, parked)
        end

        scheduler.run
        expect(order).to eq([:before_block, :unblocking, :resumed])
      end
    end

    describe "a resource pool backed by block/unblock" do
      it "unblocks waiting fibers as resources become available" do
        # Minimal pool — mirrors the connection_pool and db_query_mix benchmark patterns.
        blocker = Object.new
        waiters = []
        resources = [:r1, :r2]  # 2 slots
        served = []

        checkout = lambda do
          until resources.any?
            f = Fiber.current
            waiters << f
            begin
              Fiber.scheduler.block(blocker, nil)
            ensure
              waiters.delete(f)
            end
          end
          resources.shift
        end

        checkin = lambda do |r|
          resources << r
          Fiber.scheduler.unblock(blocker, waiters.shift) if waiters.any?
        end

        # 4 fibers competing for 2 resources — fibers 2 and 3 must wait.
        4.times do |i|
          Fiber.schedule do
            r = checkout.call
            served << i
            sleep 0.001
            checkin.call(r)
          end
        end

        scheduler.run
        expect(served).to contain_exactly(0, 1, 2, 3)
      end

      it "serves blocked fibers in FIFO order" do
        blocker = Object.new
        waiters = []
        resources = [:r]
        served = []

        checkout = lambda do
          until resources.any?
            f = Fiber.current
            waiters << f
            begin
              Fiber.scheduler.block(blocker, nil)
            ensure
              waiters.delete(f)
            end
          end
          resources.shift
        end

        checkin = lambda do |r|
          resources << r
          Fiber.scheduler.unblock(blocker, waiters.shift) if waiters.any?
        end

        # 1 resource, 3 fibers — fibers 1 and 2 queue behind fiber 0.
        3.times do |i|
          Fiber.schedule do
            r = checkout.call
            served << i
            checkin.call(r)
          end
        end

        scheduler.run
        expect(served).to eq([0, 1, 2])
      end
    end

    describe "block with a timeout" do
      it "resumes the fiber after the deadline without an explicit unblock" do
        timed_out_at = nil
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        Fiber.schedule do
          Fiber.scheduler.block(Object.new, 0.020)
          timed_out_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        scheduler.run
        expect(timed_out_at).not_to be_nil
        expect(timed_out_at - started_at).to be >= 0.015
      end
    end
  end
end
