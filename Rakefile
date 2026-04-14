# frozen_string_literal: true

require "rspec/core/rake_task"
require_relative "lib/carbon_fiber/version"

RSpec::Core::RakeTask.new(:spec)

desc "Sync VERSION from version.rb into build.zig.zon"
task :sync_version do
  version = CarbonFiber::VERSION
  zon_path = File.expand_path("build.zig.zon", __dir__)
  zon = File.read(zon_path)
  updated = zon.gsub(/\.version\s*=\s*"[^"]+"/, ".version = \"#{version}\"")
  if zon == updated
    puts "build.zig.zon already at #{version}"
  else
    File.write(zon_path, updated)
    puts "Updated build.zig.zon to #{version}"
  end
end

# Zig 0.15's Mach-O linker has issues with Xcode 26.4
#  - https://codeberg.org/ziglang/zig/pulls/31673
#  - https://codeberg.org/ziglang/zig/issues/31658
# Workaround: DEVELOPER_DIR=/dev/null makes Zig use its bundled libSystem.tbd.
desc "Compile the Zig native extension (also syncs version)"
task compile: :sync_version do
  env = RUBY_PLATFORM.include?("darwin") ? {"DEVELOPER_DIR" => "/dev/null"} : {}
  sh env, "zig", "build", "-Doptimize=ReleaseFast"
end

ZIG_VERSION = "0.15.2"

# Ruby versions to compile for. Full version must exactly match the directory
# name inside the RCD image: docker run --rm <image> ls /usr/local/rake-compiler/ruby/x86_64-linux-gnu/
RUBY_CROSS_VERSIONS = [
  {full: "3.4.8", api: "3.4.0"},
  {full: "4.0.0", api: "4.0.0"}
]

# [gem_platform_name, rcd_platform (image suffix + dir name inside container), zig_target_triple]
LINUX_PLATFORMS = [
  ["x86_64-linux", "x86_64-linux-gnu", "x86_64-linux-gnu"],
  ["aarch64-linux", "aarch64-linux-gnu", "aarch64-linux-gnu"]
]
DARWIN_PLATFORMS = %w[arm64-darwin]
ALL_PLATFORMS = LINUX_PLATFORMS.map(&:first) + DARWIN_PLATFORMS

# Cross-compile tasks
namespace :cross do
  namespace :linux do
    LINUX_PLATFORMS.each do |gem_platform, rcd_platform, zig_triple|
      desc "Cross-compile for #{gem_platform} (all configured Ruby versions)"
      task gem_platform do
        require "rake_compiler_dock"

        build_cmds = RUBY_CROSS_VERSIONS.map { |r|
          "RUBY_FULL_VERSION=#{r[:full]} RUBY_API_VERSION=#{r[:api]} " \
          "RCD_PLATFORM=#{rcd_platform} TARGET_TRIPLE=#{zig_triple} " \
          "ZIG_VERSION=#{ZIG_VERSION} bash scripts/rcd_build.sh"
        }.join(" && ")

        RakeCompilerDock.sh(build_cmds, platform: rcd_platform)
      end
    end

    desc "Cross-compile for all Linux platforms"
    task all: LINUX_PLATFORMS.map { |p, _| "cross:linux:#{p}" }
  end

  namespace :darwin do
    DARWIN_PLATFORMS.each do |gem_platform|
      desc "Build natively for #{gem_platform} (must run on a matching macOS host)"
      task gem_platform => :compile
    end
  end
end

# Gem packaging tasks
def build_platform_gem(platform)
  require "rubygems/package"
  require "fileutils"

  spec = Gem::Specification.load("carbon_fiber.gemspec")
  spec.platform = Gem::Platform.new(platform)
  spec.extensions = []  # pre-built; no compilation on install

  ext = platform.include?("darwin") ? "bundle" : "so"
  files = Dir["lib/**/*.rb"].reject { |f| File.directory?(f) } +
    Dir["lib/**/*.#{ext}"] +
    %w[README.md LICENSE]

  spec.files = files

  FileUtils.mkdir_p("pkg")
  gem_file = Gem::Package.build(spec, true)
  FileUtils.mv(gem_file, "pkg/")
  puts "Built pkg/#{File.basename(gem_file)}"
end

namespace :gem do
  LINUX_PLATFORMS.each do |gem_platform, _rcd, _zig|
    desc "Build platform gem for #{gem_platform}"
    task gem_platform do
      build_platform_gem(gem_platform)
    end
  end

  DARWIN_PLATFORMS.each do |gem_platform|
    desc "Build platform gem for #{gem_platform}"
    task gem_platform do
      build_platform_gem(gem_platform)
    end
  end

  desc "Build source gem (no precompiled extension)"
  task :source do
    require "fileutils"
    sh "gem build carbon_fiber.gemspec"
    FileUtils.mkdir_p("pkg")
    Dir["*.gem"].each { |f| FileUtils.mv(f, "pkg/") }
  end

  desc "Build all platform gems + source gem"
  task all: ALL_PLATFORMS.map { |p| "gem:#{p}" } + ["gem:source"]
end

# Benchmarks
desc "Run core and async benchmark suites"
task bench: ["bench:core", "bench:async"]

namespace :bench do
  desc "Run core benchmark suite"
  task :core do
    sh "benchmarks/bench"
  end

  namespace :core do
    desc "Run core benchmark suite in Docker (io_uring)"
    task :docker do
      sh "benchmarks/core_docker"
    end
  end

  desc "Run Async benchmark suite (stock vs. carbon backend)"
  task :async do
    sh "benchmarks/async_bench"
  end

  namespace :async do
    desc "Run Async benchmark suite in Docker (io_uring)"
    task :docker do
      sh "benchmarks/async_docker"
    end
  end
end

desc "Lint Ruby files with StandardRB"
task :lint do
  sh "bundle exec standardrb"
end

desc "Compile native extension and run specs"
task default: [:compile, :spec]
