# frozen_string_literal: true

# build / release, used by the publish workflow (rubygems/release-gem runs
# `rake release`). Each test runs in its own process, because which
# BigDecimal loads is decided once per process.
require 'bundler/gem_tasks'

desc 'Pure checks, native loading, pure against native, and the fallbacks'
task :test do
  ruby 'test/pure_test.rb'
  ruby 'test/native_test.rb'
  ruby 'test/compare_test.rb'
  Bundler.with_unbundled_env do
    ruby '--disable-gems test/fallback_test.rb'
    ruby '--disable-gems test/broken_native_test.rb'
  end
end

desc 'The comparison cases in ruby.wasm (needs node and RUBY_WASM_DIST)'
task :wasm do
  ruby 'test/wasm_test.rb'
end

task default: :test
