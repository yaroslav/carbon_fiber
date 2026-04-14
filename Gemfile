# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# stackprof uses POSIX SIGPROF and doesn't build on Windows. Benchmarks that
# use it aren't exercised in Windows CI (where we only run the fallback specs).
gem "stackprof", "~> 0.2", install_if: -> { !Gem.win_platform? }
