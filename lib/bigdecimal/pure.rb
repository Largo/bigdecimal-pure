# frozen_string_literal: true

# BigDecimal in pure Ruby, on top of Rational. lib/bigdecimal.rb loads this only
# when no native bigdecimal can be found (ruby.wasm, sandboxes without a
# compiler). Require it directly to get the pure version regardless.
#
# Like the C version: decimal strings exactly ("0.1" + "0.2" is 0.3), + - *
# exactly, division and sqrt to 20 significant digits by default,
# round/floor/ceil/truncate with digits and the ROUND_* modes, to_s ("0.3e0",
# or "0.3" with to_s('F')), comparisons with Integer, Float and Rational, to_d.
# Not: NaN and Infinity (they raise), BigDecimal.limit and .mode, precision
# bookkeeping. BigMath goes through Float, so it is good to about 15 digits.

require_relative '../bigdecimal_pure/version'

return if defined?(BigDecimal)

# rubocop:disable Lint/BigDecimalNew, Naming/PredicateMethod, Style/ReturnNilInPredicateMethodDefinition
# -- this is BigDecimal: .new is its own constructor, and infinite?/nonzero? answer
# nil as the C version does.
class BigDecimal < Numeric
  ROUND_MODE = 256
  ROUND_UP = 1
  ROUND_DOWN = 2
  ROUND_HALF_UP = 3
  ROUND_HALF_DOWN = 4
  ROUND_CEILING = 5
  ROUND_FLOOR = 6
  ROUND_HALF_EVEN = 7
  SIGN_POSITIVE_ZERO = 1
  SIGN_NEGATIVE_ZERO = -1
  SIGN_POSITIVE_FINITE = 2
  SIGN_NEGATIVE_FINITE = -2
  DIV_DIGITS = 20
  VERSION = BigDecimalPure::VERSION
  PURE = true

  DECIMAL = /\A\s*([+-]?)(\d[\d_]*)?(?:\.(\d[\d_]*)?)?(?:[eEdD]([+-]?\d+))?\s*\z/

  attr_reader :rational
  protected :rational

  def self.parse(text)
    match = DECIMAL.match(text)
    if match.nil? || (match[2].nil? && match[3].nil?)
      raise ArgumentError, "invalid value for BigDecimal(): #{text.inspect}"
    end

    whole = match[2].to_s.delete('_')
    fraction = match[3].to_s.delete('_')
    digits = Integer("#{whole}#{fraction}".sub(/\A0+(?=\d)/, '').then { |s| s.empty? ? '0' : s }, 10)
    value = Rational(digits, 10**fraction.length) * (Rational(10)**match[4].to_i)
    match[1] == '-' ? -value : value
  end

  def self.from(value, digits = 0)
    case value
    when BigDecimal then value
    when Integer then new(Rational(value))
    when Rational then new(digits.positive? ? round_significant(value, digits) : value)
    when Float
      raise FloatDomainError, value.to_s unless value.finite?

      new(digits.positive? ? round_significant(value.to_r, digits) : parse(value.to_s))
    when String then new(parse(value))
    else
      raise TypeError, "can't convert #{value.class} into BigDecimal" unless value.respond_to?(:to_r)

      new(value.to_r)
    end
  end

  # Rounds to `digits` significant digits, half up.
  def self.round_significant(value, digits)
    return Rational(0) if value.zero?

    exponent = Math.log10(value.abs.to_f).floor rescue 0 # rubocop:disable Style/RescueModifier
    scale = digits - exponent - 1
    Rational((value * (Rational(10)**scale)).round, 1) / (Rational(10)**scale)
  end

  def self.double_fig = 16
  def self.limit(*) = 0
  def self.mode(*) = 0
  def self.save_rounding_mode = yield
  def self.save_exception_mode = yield
  def self.save_limit = yield

  def initialize(rational)
    super()
    @rational = rational
    freeze
  end

  def to_r = @rational
  def to_i = @rational.truncate
  alias to_int to_i
  def to_f = @rational.to_f
  def to_d = self
  def zero? = @rational.zero?
  def nonzero? = zero? ? nil : self
  def negative? = @rational.negative?
  def positive? = @rational.positive?
  def finite? = true
  def infinite? = nil
  def nan? = false
  def integer? = false
  def real? = true
  def hash = @rational.hash
  def precs = [digits_of.length, digits_of.length + DIV_DIGITS]
  def precision = digits_of.length
  def exponent = zero? ? 0 : Math.log10(@rational.abs.to_f).floor + 1

  def sign
    if zero? then SIGN_POSITIVE_ZERO
    else negative? ? SIGN_NEGATIVE_FINITE : SIGN_POSITIVE_FINITE
    end
  end

  def coerce(other) = [BigDecimal.from(other), self]
  def -@ = BigDecimal.new(-@rational)
  def +@ = self
  def abs = BigDecimal.new(@rational.abs)

  def +(other) = BigDecimal.new(@rational + value_of(other))
  def -(other) = BigDecimal.new(@rational - value_of(other))
  def *(other) = BigDecimal.new(@rational * value_of(other))

  def /(other)
    divisor = value_of(other)
    raise ZeroDivisionError, 'divided by 0' if divisor.zero?

    exact = @rational / divisor
    terminating?(exact) ? BigDecimal.new(exact) : BigDecimal.new(BigDecimal.round_significant(exact, DIV_DIGITS))
  end
  alias quo /

  def add(other, digits) = limit(self + other, digits)
  def sub(other, digits) = limit(self - other, digits)
  def mult(other, digits) = limit(self * other, digits)

  def div(other, digits = nil)
    return (self / other).floor if digits.nil?

    divisor = value_of(other)
    raise ZeroDivisionError, 'divided by 0' if divisor.zero?

    digits.zero? ? self / other : BigDecimal.new(BigDecimal.round_significant(@rational / divisor, digits))
  end

  def %(other) = BigDecimal.new(@rational % value_of(other))
  alias modulo %
  def remainder(other) = BigDecimal.new(@rational.remainder(value_of(other)))
  def divmod(other) = [div(other), self % other]

  def **(other)
    return BigDecimal.new(@rational**other) if other.is_a?(Integer)

    BigDecimal.from(to_f**other.to_f, DIV_DIGITS)
  end
  alias power **

  def sqrt(digits = DIV_DIGITS)
    raise FloatDomainError, 'sqrt of negative value' if negative?

    BigDecimal.from(Math.sqrt(to_f), [digits, 15].min)
  end

  def <=>(other)
    other.is_a?(Numeric) ? @rational <=> value_of(other) : nil
  end

  def ==(other) = other.is_a?(Numeric) && @rational == value_of(other)
  alias eql? ==
  alias === ==
  include Comparable

  # Without digits an Integer, as in the C version; with digits a BigDecimal.
  def round(*args, half: nil)
    digits = args[0].is_a?(Integer) ? args[0] : 0
    half = { up: ROUND_HALF_UP, down: ROUND_HALF_DOWN, even: ROUND_HALF_EVEN }[half]
    mode = args.find { |arg| arg.is_a?(Symbol) } || (args[1].is_a?(Integer) ? args[1] : nil) || half || ROUND_HALF_UP
    rounded = round_to(digits, mode)
    args.empty? ? rounded.to_i : rounded
  end

  def floor(digits = 0) = digits.zero? ? @rational.floor : round_to(digits, ROUND_FLOOR)
  def ceil(digits = 0) = digits.zero? ? @rational.ceil : round_to(digits, ROUND_CEILING)
  def truncate(digits = 0) = digits.zero? ? @rational.truncate : round_to(digits, ROUND_DOWN)
  alias fix truncate

  def frac = BigDecimal.new(@rational - @rational.truncate)

  # "0.123e1" like the C version; to_s('F') for plain notation.
  def to_s(format = nil)
    return plain if format.to_s.upcase.include?('F')
    return '0.0' if zero?

    digits = digits_of
    "#{'-' if negative?}0.#{digits}e#{exponent_of}"
  end

  def inspect = to_s
  def to_digits = plain

  def _dump(_level = 0) = to_s
  def self._load(text) = from(text)

  private

  def value_of(other)
    case other
    when BigDecimal then other.rational
    when Integer, Rational then other.to_r
    when Float
      raise FloatDomainError, other.to_s unless other.finite?

      BigDecimal.parse(other.to_s)
    else
      raise TypeError, "#{other.class} can't be coerced into BigDecimal" unless other.respond_to?(:to_r)

      other.to_r
    end
  end

  def limit(value, digits)
    digits.to_i.positive? ? BigDecimal.new(BigDecimal.round_significant(value.to_r, digits.to_i)) : value
  end

  def terminating?(value)
    denominator = value.denominator
    denominator /= 2 while (denominator % 2).zero?
    denominator /= 5 while (denominator % 5).zero?
    denominator == 1
  end

  # All significant digits, without leading or trailing zeros.
  def digits_of
    text = plain.delete('-').delete('.').sub(/\A0+/, '').sub(/0+\z/, '')
    text.empty? ? '0' : text
  end

  def exponent_of
    whole, fraction = plain.delete('-').split('.')
    return whole.length if whole != '0'

    -(fraction.length - fraction.sub(/\A0+/, '').length)
  end

  # Plain decimal notation. Every value here terminates: strings, Integers and
  # Floats parse to finite decimals, and division rounds when it would not.
  def plain
    value = @rational.abs
    scale = 0
    scale += 1 until (value * (10**scale)).denominator == 1 || scale > 1000
    digits = (value * (10**scale)).round.to_s.rjust(scale + 1, '0')
    whole = digits[0...(digits.length - scale)]
    fraction = scale.zero? ? '0' : digits[(digits.length - scale)..].sub(/0+\z/, '')
    fraction = '0' if fraction.empty?
    "#{'-' if negative?}#{whole}.#{fraction}"
  end

  def round_to(digits, mode)
    scale = Rational(10)**digits
    scaled = @rational * scale
    whole = case mode
            when ROUND_UP, :up then scaled.negative? ? scaled.floor : scaled.ceil
            when ROUND_DOWN, :down, :truncate then scaled.truncate
            when ROUND_CEILING, :ceiling, :ceil then scaled.ceil
            when ROUND_FLOOR, :floor then scaled.floor
            when ROUND_HALF_DOWN, :half_down then half(scaled, :down)
            when ROUND_HALF_EVEN, :half_even, :banker then half(scaled, :even)
            else scaled.round(half: :up)
            end
    BigDecimal.new(Rational(whole) / scale)
  end

  def half(scaled, way) = scaled.round(half: way)
end
# rubocop:enable Lint/BigDecimalNew, Naming/PredicateMethod, Style/ReturnNilInPredicateMethodDefinition

module Kernel
  def BigDecimal(value, digits = 0, exception: true) # rubocop:disable Naming/MethodName
    BigDecimal.from(value, digits)
  rescue ArgumentError, TypeError
    raise if exception

    nil
  end
  module_function :BigDecimal
  public :BigDecimal
end

# bigdecimal/util: to_d on the numbers and strings.
class Integer
  def to_d = BigDecimal(self)
end

class Float
  def to_d(digits = 0) = BigDecimal(self, digits)
end

class Rational
  def to_d(digits) = BigDecimal(self, digits)
end

class String
  def to_d = BigDecimal(self, exception: false) || BigDecimal(0)
end

class NilClass
  def to_d = BigDecimal(0)
end

# bigdecimal/math, through Float: about 15 good digits whatever is asked for.
module BigMath
  module_function

  def exp(value, digits) = BigDecimal(Math.exp(value.to_f), [digits, 15].min)
  def log(value, digits) = BigDecimal(Math.log(value.to_f), [digits, 15].min)
  def sqrt(value, digits) = BigDecimal(value).sqrt(digits)
  def PI(digits) = BigDecimal(Math::PI, [digits, 15].min) # rubocop:disable Naming/MethodName
  def E(digits) = BigDecimal(Math::E, [digits, 15].min) # rubocop:disable Naming/MethodName
  def sin(value, digits) = BigDecimal(Math.sin(value.to_f), [digits, 15].min)
  def cos(value, digits) = BigDecimal(Math.cos(value.to_f), [digits, 15].min)
  def atan(value, digits) = BigDecimal(Math.atan(value.to_f), [digits, 15].min)
end
