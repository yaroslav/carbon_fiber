# frozen_string_literal: true

# Please note that Ruby specs are heavily AI-assisted.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Load the pure-Ruby fallback selector before the native extension so we can
# capture a reference to it. carbon_fiber will override ::Selector with the
# native Zig class when available, but this constant lets fallback_spec create
# schedulers with the Ruby implementation without mutating any global state.
require "carbon_fiber/native/fallback"
FALLBACK_SELECTOR_CLASS = CarbonFiber::Native::Selector

require "carbon_fiber"

NATIVE_AVAILABLE = CarbonFiber::Native.respond_to?(:available?) &&
  CarbonFiber::Native.available?

RSpec.configure do |config|
  config.order = :random
  config.disable_monkey_patching!
  config.filter_run_excluding :native_only unless NATIVE_AVAILABLE
  config.filter_run_excluding :unix_only if Gem.win_platform?
end

RSpec.shared_context "with scheduler" do
  let(:scheduler) { CarbonFiber::Scheduler.new }

  before { Fiber.set_scheduler(scheduler) }

  after do
    Fiber.set_scheduler(nil) if Fiber.scheduler == scheduler
    begin
      scheduler.close
    rescue
      nil
    end
  end
end
