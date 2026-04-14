# frozen_string_literal: true

require_relative "lib/carbon_fiber/version"

Gem::Specification.new do |spec|
  spec.name = "carbon_fiber"
  spec.version = CarbonFiber::VERSION
  spec.authors = ["Yaroslav Markin"]
  spec.email = ["yaroslav@markin.net"]

  spec.summary = "High-performance Ruby Fiber Scheduler backed by Zig with libxev. Pure Ruby and gem async."
  spec.description = "A high-performance Ruby Fiber Scheduler using a Zig native extension with libxev (io_uring on Linux, kqueue on macOS). Works as a pure Ruby Fiber Scheduler, as well as with the async gem."
  spec.homepage = "https://github.com/yaroslav/carbon_fiber"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "homepage_uri" => spec.homepage,
    "changelog_uri" => "https://github.com/yaroslav/carbon_fiber/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/yaroslav/carbon_fiber/issues",
    "documentation_uri" => "https://rubydoc.info/gems/carbon_fiber"
  }

  # Source gem ships only Ruby files. The pure-Ruby fallback in
  # lib/carbon_fiber/native/fallback.rb makes it functional on any platform.
  # Platform gems override spec.files in the Rakefile gem:* tasks before packaging.
  spec.files = Dir["lib/**/*.rb"].reject { |f| File.directory?(f) } +
    %w[README.md CHANGELOG.md LICENSE]

  spec.require_paths = ["lib"]

  spec.add_development_dependency "async", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler-dock", "~> 1.11"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "stackprof", "~> 0.2"
  spec.add_development_dependency "standard", "~> 1.0"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.add_development_dependency "lefthook", "~> 2.1.5"
end
