# frozen_string_literal: true

require "spec_helper"
require "carbon_fiber/async"

# Ruby 4.1 (ruby/ruby#18483) changed the buffered scheduler hooks from
# io_read(io, buffer, length, offset) to io_read(io, buffer, offset, length)
# and made them single-transfer. IO::Buffer::VERSION >= 3 signals the new
# contract. Both hook generations are defined on every Ruby; the public
# names are aliased to the matching generation at load time.
RSpec.describe "scheduler I/O contract selection" do
  describe "CarbonFiber.io_contract_v4?" do
    it "is false when IO::Buffer::VERSION is not defined" do
      # Ruby 3.4 through 4.0 define no IO::Buffer::VERSION.
      skip "host Ruby defines IO::Buffer::VERSION" if defined?(IO::Buffer::VERSION)
      expect(CarbonFiber.io_contract_v4?).to be false
    end

    context "with a stubbed IO::Buffer::VERSION" do
      after do
        IO::Buffer.send(:remove_const, :VERSION) if @stubbed
      end

      def stub_version(value)
        skip "host Ruby defines IO::Buffer::VERSION" if defined?(IO::Buffer::VERSION)
        @stubbed = true
        IO::Buffer.const_set(:VERSION, value)
      end

      it "is true for version 3" do
        stub_version(3)
        expect(CarbonFiber.io_contract_v4?).to be true
      end

      it "is true for versions above 3" do
        stub_version(4)
        expect(CarbonFiber.io_contract_v4?).to be true
      end

      it "is false for version 2" do
        stub_version(2)
        expect(CarbonFiber.io_contract_v4?).to be false
      end

      it "tolerates a String version constant" do
        stub_version("3")
        expect(CarbonFiber.io_contract_v4?).to be true
      end
    end
  end

  describe CarbonFiber::Scheduler do
    it "defines both hook generations for io_read" do
      expect(described_class.instance_method(:io_read_v3).parameters)
        .to eq([%i[req io], %i[req buffer], %i[req length], %i[opt offset]])
      expect(described_class.instance_method(:io_read_v4).parameters)
        .to eq([%i[req io], %i[req buffer], %i[req offset], %i[req length]])
    end

    it "defines both hook generations for io_write" do
      expect(described_class.instance_method(:io_write_v3).parameters)
        .to eq([%i[req io], %i[req buffer], %i[req length], %i[opt offset]])
      expect(described_class.instance_method(:io_write_v4).parameters)
        .to eq([%i[req io], %i[req buffer], %i[req offset], %i[req length]])
    end

    it "aliases the public hooks to the generation matching this Ruby" do
      generation = CarbonFiber.io_contract_v4? ? "v4" : "v3"
      expect(described_class.instance_method(:io_read))
        .to eq(described_class.instance_method(:"io_read_#{generation}"))
      expect(described_class.instance_method(:io_write))
        .to eq(described_class.instance_method(:"io_write_#{generation}"))
    end
  end

  describe CarbonFiber::Async::Selector do
    it "defines both hook generations for io_read" do
      expect(described_class.instance_method(:io_read_v3).parameters)
        .to eq([%i[req fiber], %i[req io], %i[req buffer], %i[req length], %i[opt offset]])
      expect(described_class.instance_method(:io_read_v4).parameters)
        .to eq([%i[req fiber], %i[req io], %i[req buffer], %i[req offset], %i[req length]])
    end

    it "defines both hook generations for io_write" do
      expect(described_class.instance_method(:io_write_v3).parameters)
        .to eq([%i[req fiber], %i[req io], %i[req buffer], %i[req length], %i[opt offset]])
      expect(described_class.instance_method(:io_write_v4).parameters)
        .to eq([%i[req fiber], %i[req io], %i[req buffer], %i[req offset], %i[req length]])
    end

    it "aliases the public hooks to the generation matching this Ruby" do
      generation = CarbonFiber.io_contract_v4? ? "v4" : "v3"
      expect(described_class.instance_method(:io_read))
        .to eq(described_class.instance_method(:"io_read_#{generation}"))
      expect(described_class.instance_method(:io_write))
        .to eq(described_class.instance_method(:"io_write_#{generation}"))
    end
  end

  describe "fallback selector" do
    it "accepts the io_contract_v4 writer as a no-op" do
      selector = FALLBACK_SELECTOR_CLASS.new(Fiber.current)
      expect { selector.io_contract_v4 = true }.not_to raise_error
    end
  end
end
