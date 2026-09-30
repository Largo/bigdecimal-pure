# frozen_string_literal: true

# The pure class, forced with BIGDECIMAL_PURE=1, against known values. Needs
# no native bigdecimal; test/compare_test.rb holds it against the native one
# case by case. Runs on its own: ruby test/pure_test.rb
ENV['BIGDECIMAL_PURE'] = '1'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'bigdecimal'
require 'bigdecimal/util'
require 'bigdecimal/math'
abort 'the native bigdecimal loaded; expected the pure one' unless BigDecimalPure.pure?

FAILED = [] # rubocop:disable Style/MutableConstant -- check collects into it

def check(label)
  ok, detail = yield
  puts "  #{ok ? 'ok  ' : 'FAIL'} #{label}#{" — #{detail}" unless ok}"
  FAILED << label unless ok
rescue StandardError => e
  puts "  FAIL #{label} — #{e.class}: #{e.message}"
  FAILED << label
end

def same(actual, expected) = [actual == expected, "got #{actual.inspect}, want #{expected.inspect}"]
def d(text) = BigDecimal(text)

def raised(klass)
  yield
  [false, "no #{klass}"]
rescue klass
  [true, nil]
end

def isolated(&) = BigDecimal.save_exception_mode { BigDecimal.save_rounding_mode { BigDecimal.save_limit(&) } }

puts '== numbers'
check('decimal strings are exact: 0.1 + 0.2 is 0.3') { same((d('0.1') + d('0.2')).to_s('F'), '0.3') }
check('to_s like the C version') { same([d('1.23').to_s, d('-0.00123').to_s, d('0').to_s], %w[0.123e1 -0.123e-2 0.0]) }
check("to_s('F'), grouping and signs") do
  same([d('12345.6789').to_s('3F'), d('12345.6789').to_s('+E'), d('1e20').to_s('F')],
       ['12 345.678 9', '+0.123456789e5', '100000000000000000000.0'])
end
check('underscores and exponent letters parse as in C') do
  same([d('1_000.5').to_s('F'), d('1.5d2').to_i], ['1000.5', 150])
end
check('invalid text raises, or nil with exception: false') do
  same([raised(ArgumentError) { d('1e') }.first, BigDecimal('abc', exception: false)], [true, nil])
end
check('String#to_d reads as far as it can') { same(['12abc'.to_d.to_i, 'abc'.to_d.zero?], [12, true]) }
check('precision, scale, n_significant_digits') do
  same([d('123.456').precision_scale, d('1e-20').precision, d('1e20').n_significant_digits], [[6, 3], 20, 1])
end
check('Integer, Float and Rational operands') do
  same([(2 + d('0.5')).to_s, (d('0.1') + 0.2).to_s, (d(1) + Rational(1, 3)).to_s],
       ['0.25e1', '0.3e0', '0.133333333333333333333333333333333e1'])
end
check('Float to BigDecimal: shortest digits, or n digits') do
  same([BigDecimal(0.1).to_s, 2.5.to_d(1).to_s], %w[0.1e0 0.2e1])
end
check('Marshal round trip') { same(Marshal.load(Marshal.dump(d('-1.25'))), d('-1.25')) }
check('hash and eql? agree, so it works as a Hash key') { same({ d('1.0') => :a }[d('1')], :a) }

puts '== NaN, infinity, -0'
check('NaN and the infinities parse') do
  same([d('NaN').nan?, d('Infinity').infinite?, d('-Infinity').infinite?], [true, 1, -1])
end
check('division by zero gives Infinity or NaN, as in C') do
  same([(d(1) / 0).to_s, (d(-1) / 0).to_s, (d(0) / 0).to_s], %w[Infinity -Infinity NaN])
end
check('NaN is not equal to itself, and does not compare') do
  nan = d('NaN')
  same([nan == nan, nan <=> 1, nan < 1], [false, nil, false]) # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands
end
check('-0 keeps its sign') { same([d('-0').to_s, d('-0').sign, (d('-0') * 5).to_s], ['-0.0', -1, '-0.0']) }
check('Infinity arithmetic') { same([(BigDecimal::INFINITY + 1).to_s, (BigDecimal::INFINITY * 0).nan?], ['Infinity', true]) }
check('to_i of Infinity raises') { raised(FloatDomainError) { BigDecimal::INFINITY.to_i } }
check('integer division by zero still raises ZeroDivisionError') { raised(ZeroDivisionError) { d(1).div(0) } }

puts '== BigDecimal.mode and BigDecimal.limit'
check('EXCEPTION_ZERODIVIDE makes 1/0 raise') do
  isolated do
    BigDecimal.mode(BigDecimal::EXCEPTION_ZERODIVIDE, true)
    raised(FloatDomainError) { d(1) / 0 }
  end
end
check('EXCEPTION_NaN makes NaN raise') do
  isolated do
    BigDecimal.mode(BigDecimal::EXCEPTION_NaN, true)
    raised(FloatDomainError) { d('NaN') }
  end
end
check('save_exception_mode restores the mode') do
  BigDecimal.save_exception_mode { BigDecimal.mode(BigDecimal::EXCEPTION_ALL, true) }
  same(BigDecimal.mode(BigDecimal::EXCEPTION_ALL), 0)
end
check('ROUND_MODE applies to round and to division') do
  isolated do
    BigDecimal.mode(BigDecimal::ROUND_MODE, :half_even)
    same([d('2.5').round, d('2.345').round(2).to_s, (d(2) / 3).to_s],
         [2, '0.234e1', '0.66666666666666666666666666666667e0'])
  end
end
check('round with a mode, floor, ceil, truncate') do
  same([d('2.345').round(2, :down).to_s, d('-1.5').floor, d('-1.5').ceil, d('-1.5').truncate,
        d('2.5').round(half: :even).to_s],
       ['0.234e1', -2, -1, -1, '0.2e1'])
end
check('limit rounds + - * / to that many digits') do
  isolated do
    BigDecimal.limit(5)
    same([(d('1.234567') + 0).to_s, (d(1) / 3).to_s, (d('123456') * 1).to_s], %w[0.12346e1 0.33333e0 0.12346e6])
  end
end
check('limit leaves an explicit precision alone') do
  isolated do
    BigDecimal.limit(3)
    same([d(1).div(3, 10).to_s, d('1.23456').round(4).to_s], %w[0.3333333333e0 0.12346e1])
  end
end
check('save_limit restores the limit') do
  BigDecimal.save_limit { BigDecimal.limit(7) }
  same(BigDecimal.limit, 0)
end

puts '== precision of each operation'
check('/ keeps the larger precision plus 16, at least 32 digits') do
  same([(d(1) / 3).precision, (d('1.2345678901234567890123') / 7).precision], [32, 39])
end
check('div, add, sub, mult with a precision') do
  same([d(1).div(3, 5).to_s, d('111111.111').add(1, 3).to_s, d('555555.555').mult(3, 6).to_s],
       %w[0.33333e0 0.111e6 0.166667e7])
end
check('% and divmod round toward negative infinity, remainder toward zero') do
  same([(d(-7) % 2).to_s, d(-7).divmod(2).map(&:to_s), d(-7).remainder(2).to_s], ['0.1e1', ['-4', '0.1e1'], '-0.1e1'])
end
check('** with an Integer is exact') { same((d('1.5')**10).to_s, '0.576650390625e2') }
check('** with a fraction follows the precision rules of the C version') do
  same([(d(2)**d('0.5')).to_s, (d(2)**-1).to_s], %w[0.14142135623730950488016887242097e1 0.5e0])
end

puts '== sqrt and BigMath, to the precision asked for'
check('sqrt(2) to 50 digits') { same(d(2).sqrt(50).to_s, '0.14142135623730950488016887242096980785696718753769e1') }
check('an exact square root stays exact in every rounding mode') do
  isolated do
    BigDecimal.mode(BigDecimal::ROUND_MODE, :down)
    same(d(4).sqrt(20).to_s, '0.2e1')
  end
end
check('PI to 50 digits') { same(BigMath.PI(50).to_s, '0.31415926535897932384626433832795028841971693993751e1') }
check('PI to 500 digits agrees with PI to 50') { same(BigMath.PI(500).round(49), BigMath.PI(50)) }
check('E to 50 digits') { same(BigMath.E(50).to_s, '0.27182818284590452353602874713526624977572470937e1') }
check('log(2) to 50 digits') { same(BigMath.log(2, 50).to_s, '0.69314718055994530941723212145817656807550013436026e0') }
check('sin(1) to 30 digits') { same(BigMath.sin(1, 30).to_s, '0.84147098480789650665250232163e0') }
check('atan(1) is pi/4') { same(BigMath.atan(1, 40), BigMath.PI(45).div(4, 40)) }
check('gamma(1/2) is sqrt(pi)') { same(BigMath.gamma(d('0.5'), 30), BigMath.PI(40).sqrt(30)) }
check('erf(1) to 30 digits') { same(BigMath.erf(1, 30).to_s, '0.842700792949714869341220635083e0') }
check('log10(1000) is 3 in every rounding mode') do
  isolated do
    BigDecimal.mode(BigDecimal::ROUND_MODE, :down)
    same(BigMath.log10(1000, 20).to_s, '0.3e1')
  end
end
check('exp far beyond Float') { same(BigMath.exp(1000, 10).to_s, '0.1970071114e435') }

puts
abort "#{FAILED.size} check(s) failed" unless FAILED.empty?
puts 'All checks passed.'
