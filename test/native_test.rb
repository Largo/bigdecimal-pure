# frozen_string_literal: true

# With the bigdecimal gem installed, `require 'bigdecimal'` through this gem's
# lib must give the native class. Runs on its own: ruby test/native_test.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'bigdecimal'
require 'bigdecimal/util'

abort 'expected the native bigdecimal' unless BigDecimalPure.native?
abort 'native to_d missing' unless '1.10'.to_d.to_s('F') == '1.1'
abort 'native class is not C' if BigDecimal.method(:save_rounding_mode).source_location
puts "native bigdecimal #{BigDecimal::VERSION} loaded through bigdecimal-pure. ok"
