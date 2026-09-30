# frozen_string_literal: true

# Prints one line per case of test/support/cases.rb: its result or the error
# it raised. test/compare_test.rb runs this once with the native bigdecimal
# and once with BIGDECIMAL_PURE=1 and compares the output.
require 'timeout'
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'bigdecimal'
require 'bigdecimal/util'
require 'bigdecimal/math'
require_relative 'cases'

def show(value)
  case value
  when BigDecimal then value.inspect
  when Array then "[#{value.map { |v| show(v) }.join(', ')}]"
  else "#{value.inspect}:#{value.class}"
  end
end

def evaluate(source)
  BigDecimal.save_exception_mode do
    BigDecimal.save_rounding_mode do
      BigDecimal.save_limit do
        Timeout.timeout(20) { show(eval(source, TOPLEVEL_BINDING.dup)) } # rubocop:disable Security/Eval
      end
    end
  end
rescue Timeout::Error
  '!! timeout'
rescue StandardError, ScriptError => e
  "!! #{e.class}: #{e.message}"
end

Cases.all.each_with_index do |source, i|
  puts "#{i}\t#{evaluate(source.sub(/\A~\d+:/, ''))}"
end
