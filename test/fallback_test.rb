# frozen_string_literal: true

# Without any native bigdecimal on the load path, the pure class answers
# `require 'bigdecimal'` by itself. Run with gems disabled, outside Bundler, so
# nothing activates the bigdecimal gem; the default-gem copy that Rubies before
# 3.4 carry is taken off the load path here:
#   ruby --disable-gems test/fallback_test.rb
exts = %w[.rb .so .bundle .dll].map { |ext| "bigdecimal#{ext}" }
$LOAD_PATH.reject! { |dir| exts.any? { |name| File.exist?(File.join(dir, name)) } }
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'bigdecimal'
require 'bigdecimal/util'

abort 'expected the pure bigdecimal' unless BigDecimalPure.pure?
abort 'wrong sum' unless (BigDecimal('0.1') + '0.2'.to_d).to_s('F') == '0.3'
puts "pure bigdecimal-pure #{BigDecimal::VERSION} loaded as the fallback. ok"
