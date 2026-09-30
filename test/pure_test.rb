# frozen_string_literal: true

# The pure class, forced with BIGDECIMAL_PURE=1. Runs on its own:
# ruby test/pure_test.rb
ENV['BIGDECIMAL_PURE'] = '1'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'bigdecimal'
require 'bigdecimal/util'
abort 'the native bigdecimal loaded; expected the pure one' unless BigDecimalPure.pure?


FAILED = []

def check(label)
  ok, detail = yield
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}#{" — #{detail}" unless ok}"
  FAILED << label unless ok
rescue StandardError => e
  puts "  FAIL #{label} — #{e.class}: #{e.message}"
  FAILED << label
end

def same(actual, expected) = [actual == expected, "got #{actual.inspect}, want #{expected.inspect}"]

puts '== BigDecimal stand-in'
check('decimal strings are exact: 0.1 + 0.2 is 0.3') { same((BigDecimal('0.1') + BigDecimal('0.2')).to_s('F'), '0.3') }
check('to_s like the C version') { same(BigDecimal('1.23').to_s, '0.123e1') }
check('small and negative numbers') { same(BigDecimal('-0.00123').to_s, '-0.123e-2') }
check('zero') { same(BigDecimal('0').to_s, '0.0') }
check('exponent notation parses') { same(BigDecimal('1.5e3').to_i, 1500) }
check('multiplication stays exact') { same((BigDecimal('19.99') * 3).to_s('F'), '59.97') }
check('division rounds to 20 significant digits') { same((BigDecimal('1') / 3).to_s, '0.33333333333333333333e0') }
check('a terminating division stays exact') { same((BigDecimal('1') / 8).to_s('F'), '0.125') }
check('division by zero raises') { [(BigDecimal('1') / 0 rescue $!.class) == ZeroDivisionError, 'no ZeroDivisionError'] } # rubocop:disable Style/RescueModifier
check('round half up to digits') { same(BigDecimal('2.345').round(2).to_s('F'), '2.35') }
check('round to an integer returns an Integer') { same(BigDecimal('2.5').round, 3) }
check('banker\'s rounding') { same(BigDecimal('2.345').round(2, BigDecimal::ROUND_HALF_EVEN).to_s('F'), '2.34') }
check('floor, ceil, truncate') { same([BigDecimal('-1.5').floor, BigDecimal('-1.5').ceil, BigDecimal('-1.5').truncate], [-2, -1, -1]) }
check('comparisons with Integer, Float and Rational') do
  x = BigDecimal('1.5')
  same([x > 1, x == 1.5, x < Rational(2), 1 < x, [x, BigDecimal('0.5')].max == x], [true, true, true, true, true])
end
check('coercion: Integer + BigDecimal') { same((2 + BigDecimal('0.5')).to_s('F'), '2.5') }
check('Float in arithmetic is taken by its decimal text') { same((BigDecimal('0.1') + 0.2).to_s('F'), '0.3') }
check('is_a? Numeric and BigDecimal') { same([BigDecimal('1').is_a?(BigDecimal), BigDecimal('1').is_a?(Numeric)], [true, true]) }
check('to_f and to_r') { same([BigDecimal('0.25').to_f, BigDecimal('0.25').to_r], [0.25, Rational(1, 4)]) }
check('to_d from bigdecimal/util') { same(['1.10'.to_d.to_s('F'), 3.to_d.to_s('F'), 0.5.to_d.to_s('F')], ['1.1', '3.0', '0.5']) }
check('invalid text raises, or nil with exception: false') do
  same([(BigDecimal('abc') rescue :raised), BigDecimal('abc', exception: false)], [:raised, nil]) # rubocop:disable Style/RescueModifier
end
check('sum of money in a loop has no float error') { same(Array.new(10) { BigDecimal('0.1') }.sum(BigDecimal(0)).to_s('F'), '1.0') }
check('BigMath is there, about 15 digits') { [(BigMath.exp(BigDecimal('1'), 20) - Math::E).abs < 1e-14, BigMath.exp(1, 20).to_s] }
check('hash and eql? agree, so it works as a Hash key') { same({ BigDecimal('1.0') => :a }[BigDecimal('1')], :a) }

puts
abort "#{FAILED.size} check(s) failed" unless FAILED.empty?
puts 'All checks passed.'
