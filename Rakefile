# frozen_string_literal: true

require "rspec/core/rake_task"
require "shellwords"
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
  fix_macos_install_names if RUBY_PLATFORM.include?("darwin")
end

# Strip non-portable artifacts the Zig linker leaves in the macOS bundle:
# absolute LC_RPATH entries (from Zig's addLibraryPath, which targets the
# host ruby's libdir) and any absolute libruby reference that may slip back
# in if zig_rb's contamination returns. Re-codesign because Apple Silicon
# rejects unsigned binaries and modifying load commands invalidates the
# signature.
def fix_macos_install_names
  bundles = Dir["lib/carbon_fiber/*/carbon_fiber_native.bundle"]
  raise "No macOS bundles to post-process under lib/carbon_fiber/*/" if bundles.empty?

  bundles.each do |bundle|
    deps = `otool -L #{bundle.shellescape}`
    libruby_line = deps.lines.find { |l| l.match?(%r{/libruby\.\d+\.\d+\.dylib}) }
    if libruby_line
      old = libruby_line.match(/^\s*(\S.*?)\s+\(/)[1]
      if old.start_with?("/")
        new = "@rpath/#{File.basename(old)}"
        sh "install_name_tool", "-change", old, new, bundle
      end
    end

    rpaths = `otool -l #{bundle.shellescape}`.scan(/^\s+path\s+(.+?)\s+\(offset \d+\)/).flatten
    rpaths.each do |rpath|
      sh "install_name_tool", "-delete_rpath", rpath, bundle if rpath.start_with?("/")
    end

    sh "codesign", "--sign", "-", "--force", bundle

    final_libs = `otool -L #{bundle.shellescape}`
    leaked = final_libs.lines.find do |l|
      next false unless l.start_with?("\t/")
      next false if l.match?(%r{^\t/usr/lib/}) || l.match?(%r{^\t/System/})
      true
    end
    raise "Non-portable dylib in #{bundle}: #{leaked.strip}\n\n#{final_libs}" if leaked

    final_rpaths = `otool -l #{bundle.shellescape}`.scan(/^\s+path\s+(.+?)\s+\(offset \d+\)/).flatten
    leaked_rpath = final_rpaths.find { |r| r.start_with?("/") }
    raise "Non-portable LC_RPATH in #{bundle}: #{leaked_rpath}" if leaked_rpath
  end
end

ZIG_VERSION = "0.15.2"

# Ruby versions to compile for. Full version must exactly match the directory
# name inside the RCD image: docker run --rm <image> ls /usr/local/rake-compiler/ruby/x86_64-linux-gnu/
RUBY_CROSS_VERSIONS = [
  {full: "3.4.8", api: "3.4.0"},
  {full: "4.0.0", api: "4.0.0"}
]

# [gem_platform_name, rcd_platform (image suffix), zig_target_triple]
# rcd_platform also names the dir inside the RCD container *most* of the time;
# scripts/rcd_build.sh discovers the actual path because the x86_64-musl image
# uses x86_64-unknown-linux-musl as its top dir.
LINUX_PLATFORMS = [
  ["x86_64-linux", "x86_64-linux-gnu", "x86_64-linux-gnu"],
  ["aarch64-linux", "aarch64-linux-gnu", "aarch64-linux-gnu"],
  ["x86_64-linux-musl", "x86_64-linux-musl", "x86_64-linux-musl"],
  ["aarch64-linux-musl", "aarch64-linux-musl", "aarch64-linux-musl"]
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
