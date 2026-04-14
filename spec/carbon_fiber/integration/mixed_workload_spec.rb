# frozen_string_literal: true

require "spec_helper"

RSpec.describe CarbonFiber::Scheduler do
  include_context "with scheduler"

  describe "running mixed concurrent workloads" do
    describe "sleeping, IO, and Queue work all running at once" do
      it "completes every kind of fiber without any of them blocking the others", :unix_only do
        results = []
        queue = Queue.new
        reader, writer = IO.pipe

        Fiber.schedule {
          sleep 0.02
          results << :slept
        }
        Fiber.schedule { results << queue.pop }
        Fiber.schedule { results << reader.gets.chomp }
        Fiber.schedule { queue.push(:queued) }
        Fiber.schedule {
          writer.puts "piped"
          writer.close
        }

        scheduler.run
        expect(results).to contain_exactly(:slept, :queued, "piped")
      ensure
        begin
          reader.close
        rescue
          nil
        end
        begin
          writer.close
        rescue
          nil
        end
      end
    end

    describe "a large number of concurrent fibers" do
      it "runs 100 fibers to completion" do
        completed = []
        100.times { |i|
          Fiber.schedule {
            sleep 0.001
            completed << i
          }
        }
        scheduler.run
        expect(completed.sort).to eq((0..99).to_a)
      end
    end

    describe "a fiber that schedules more fibers" do
      it "runs all nested fibers to completion" do
        results = []

        Fiber.schedule do
          3.times { |i| Fiber.schedule { results << i } }
        end

        scheduler.run
        expect(results).to contain_exactly(0, 1, 2)
      end

      it "handles multiple levels of nesting" do
        results = []

        Fiber.schedule do
          Fiber.schedule do
            Fiber.schedule { results << :deep }
            results << :middle
          end
          results << :top
        end

        scheduler.run
        expect(results).to contain_exactly(:top, :middle, :deep)
      end
    end

    describe "a pipeline of fibers passing data through a Queue" do
      it "threads data through producer → transformer → consumer" do
        raw_q = Queue.new
        cooked_q = Queue.new
        output = []

        # Producer
        Fiber.schedule { 3.times { |i| raw_q.push(i) } }

        # Transformer
        Fiber.schedule { 3.times { cooked_q.push(raw_q.pop * 10) } }

        # Consumer
        Fiber.schedule { 3.times { output << cooked_q.pop } }

        scheduler.run
        expect(output.sort).to eq([0, 10, 20])
      end
    end
  end
end
