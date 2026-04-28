# frozen_string_literal: true

# Loads the native Zig extension or falls back to a pure-Ruby implementation.
# Set +CARBON_FIBER_FORCE_FALLBACK=1+ to skip the native extension.

require "rbconfig"

native_paths = [
  File.expand_path(
    "#{RbConfig::CONFIG["ruby_version"]}/carbon_fiber_native.#{RbConfig::CONFIG["DLEXT"]}",
    __dir__
  ),
  File.expand_path(
    "#{RbConfig::CONFIG["ruby_version"]}/carbon_fiber_native.so",
    __dir__
  ),
  File.expand_path(
    "#{RbConfig::CONFIG["ruby_version"]}/carbon_fiber_native",
    __dir__
  )
]

# A native binary that exists but fails to load raises LoadError instead of
# silently falling back, so dyld/packaging bugs surface immediately.
native_loaded =
  if ENV["CARBON_FIBER_FORCE_FALLBACK"] == "1"
    false
  else
    existing = native_paths.find { |path| File.exist?(path) }
    if existing
      require existing
      true
    else
      false
    end
  end

native_available =
  native_loaded &&
  defined?(CarbonFiber::Native) &&
  CarbonFiber::Native.respond_to?(:available?) &&
  CarbonFiber::Native.available?

require_relative "native/fallback" unless native_available
