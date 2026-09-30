# frozen_string_literal: true

# build / release, used by the publish workflow (rubygems/release-gem runs
# `rake release`). Each test runs in its own process, because which
# BigDecimal loads is decided once per process.
require 'bundler/gem_tasks'

task :test do
  ruby 'test/pure_test.rb'
  ruby 'test/native_test.rb'
  Bundler.with_unbundled_env { ruby '--disable-gems test/fallback_test.rb' }
end
task default: :test
