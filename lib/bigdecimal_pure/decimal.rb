# frozen_string_literal: true

require_relative 'version'

# BigDecimal in pure Ruby, modelled on bigdecimal 4.x.
#
# A finite value is a sign, an Integer coefficient without trailing zeros and
# a decimal exponent: sign * coef * 10**exp. NaN and the two infinities are
# kinds of their own, and zero keeps its sign as in the C version. Every
# operation computes the exact result and then rounds where the C version
# rounds, with the same rules for how many digits: + - * are exact unless
# BigDecimal.limit or a precision argument says otherwise, / keeps the larger
# operand's precision plus 16 digits (at least 32).
#
# The C version keeps the digits in 9-digit words. Where that shows through
# (the precision a Rational operand is converted with, the prefix of _dump,
# ROUND_UP to a position far left of the number) this class counts the words
# it would have used.
class BigDecimal < Numeric
  BASE = 1_000_000_000

  EXCEPTION_ALL = 0xff
  EXCEPTION_NaN = 0x02 # rubocop:disable Naming/ConstantName
  EXCEPTION_INFINITY = 0x01
  EXCEPTION_UNDERFLOW = 0x04
  EXCEPTION_OVERFLOW = 0x01 # the same bit as INFINITY, as in the C version
  EXCEPTION_ZERODIVIDE = 0x10

  ROUND_MODE = 0x100
  ROUND_UP = 1
  ROUND_DOWN = 2
  ROUND_HALF_UP = 3
  ROUND_HALF_DOWN = 4
  ROUND_CEILING = 5
  ROUND_FLOOR = 6
  ROUND_HALF_EVEN = 7

  SIGN_NaN = 0 # rubocop:disable Naming/ConstantName
  SIGN_POSITIVE_ZERO = 1
  SIGN_NEGATIVE_ZERO = -1
  SIGN_POSITIVE_FINITE = 2
  SIGN_NEGATIVE_FINITE = -2
  SIGN_POSITIVE_INFINITE = 3
  SIGN_NEGATIVE_INFINITE = -3

  VERSION = BigDecimalPure::VERSION
  PURE = true

  DOUBLE_FIG = 16
  ROUNDING_NAMES = {
    up: ROUND_UP, down: ROUND_DOWN, truncate: ROUND_DOWN,
    half_up: ROUND_HALF_UP, default: ROUND_HALF_UP, half_down: ROUND_HALF_DOWN,
    half_even: ROUND_HALF_EVEN, banker: ROUND_HALF_EVEN,
    ceiling: ROUND_CEILING, ceil: ROUND_CEILING, floor: ROUND_FLOOR
  }.freeze
  # The decimal exponent range of the C version: 9 * the word exponent range.
  MAX_E10 = 9_223_372_036_854_775_800
  MIN_E10 = -9_223_372_036_854_775_808
  # Below this exponent no result can leave the range, so _make skips the check.
  SAFE_EXP = 9_000_000_000_000_000_000
  POW10 = Array.new(40) { |i| 10**i }.freeze
  SPACE = [0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d].freeze
  SPECIAL_STRINGS = [['Infinity', :inf, 1], ['+Infinity', :inf, 1], ['-Infinity', :inf, -1], ['NaN', :nan, 0]].freeze
  KEY_EXCEPTION = :__bigdecimal_pure_exception_mode__
  KEY_ROUNDING = :__bigdecimal_pure_rounding_mode__
  KEY_LIMIT = :__bigdecimal_pure_precision_limit__
  private_constant :DOUBLE_FIG, :ROUNDING_NAMES, :MAX_E10, :MIN_E10, :SAFE_EXP, :POW10, :SPACE,
                   :SPECIAL_STRINGS, :KEY_EXCEPTION, :KEY_ROUNDING, :KEY_LIMIT

  class << self
    alias _alloc new
    private :_alloc
    undef_method :new

    def allocate = raise(TypeError, 'allocator undefined for BigDecimal')
  end

  # ---- modes and limit, per thread (fiber) like the C version -------------

  def self.mode(which, value = nil)
    flag = _num2int(which)
    if flag.anybits?(EXCEPTION_ALL)
      current = _exception_mode
      return current if value.nil?
      raise ArgumentError, 'second argument must be true or false' unless [true, false].include?(value)

      [EXCEPTION_INFINITY, EXCEPTION_NaN, EXCEPTION_UNDERFLOW, EXCEPTION_ZERODIVIDE].each do |bit|
        current = value ? current | bit : current & ~bit if flag.anybits?(bit)
      end
      Thread.current[KEY_EXCEPTION] = current
      return current
    end
    raise TypeError, 'first argument for BigDecimal.mode invalid' unless flag == ROUND_MODE
    return _rounding_mode if value.nil?

    Thread.current[KEY_ROUNDING] = _rounding_mode_of(value)
  end

  def self.limit(digits = nil)
    current = _limit
    unless digits.nil?
      n = _num2int(digits)
      raise ArgumentError, 'argument must be positive' if n.negative?

      Thread.current[KEY_LIMIT] = n
    end
    current
  end

  def self.save_exception_mode
    saved = _exception_mode
    begin
      yield
    ensure
      Thread.current[KEY_EXCEPTION] = saved
    end
  end

  def self.save_rounding_mode
    saved = _rounding_mode
    begin
      yield
    ensure
      Thread.current[KEY_ROUNDING] = saved
    end
  end

  def self.save_limit
    saved = _limit
    begin
      yield
    ensure
      Thread.current[KEY_LIMIT] = saved
    end
  end

  def self.double_fig = DOUBLE_FIG

  def self._exception_mode = Thread.current[KEY_EXCEPTION] || 0 # :nodoc:
  def self._rounding_mode = Thread.current[KEY_ROUNDING] || ROUND_HALF_UP # :nodoc:
  def self._limit = Thread.current[KEY_LIMIT] || 0 # :nodoc:

  # ROUND_* as an Integer or one of its names; Strings are refused as in C.
  def self._rounding_mode_of(value) # :nodoc:
    if value.is_a?(Symbol)
      ROUNDING_NAMES.fetch(value) { raise ArgumentError, "invalid rounding mode (#{value})" }
    else
      mode = _num2int(value)
      raise ArgumentError, "invalid rounding mode (#{value})" unless (ROUND_UP..ROUND_HALF_EVEN).cover?(mode)

      mode
    end
  end

  # round's half: option; nil means the current rounding mode.
  def self._half_option(opts) # :nodoc:
    mode = opts[:half]
    return _rounding_mode if mode.nil?

    text = if mode.is_a?(Symbol)
             mode.to_s
           else
             (mode.respond_to?(:to_str) ? mode.to_str : nil)
           end
    case text&.downcase
    when 'up' then ROUND_HALF_UP
    when 'even' then ROUND_HALF_EVEN
    when 'down' then ROUND_HALF_DOWN
    else raise ArgumentError, "invalid rounding mode (#{text || mode})"
    end
  end

  # FloatDomainError when the exception mode has this bit.
  def self._raise_if(bit, message) # :nodoc:
    raise FloatDomainError, message if _exception_mode.anybits?(bit)
  end

  # ---- construction --------------------------------------------------------

  # A finite value; strips trailing zeros and keeps the exponent in range.
  def self._make(sign, coef, exp) # :nodoc:
    return sign.negative? ? N_ZERO : P_ZERO if coef.zero?

    if (coef % 10).zero?
      while (coef % 100_000_000).zero?
        coef /= 100_000_000
        exp += 8
      end
      while (coef % 10).zero?
        coef /= 10
        exp += 1
      end
    end
    return _out_of_range(sign, coef, exp) if exp > SAFE_EXP || exp < -SAFE_EXP

    _alloc(nil, sign, coef, exp)
  end

  def self._out_of_range(sign, coef, exp) # :nodoc:
    e10 = exp + _ndigits(coef)
    if e10 > MAX_E10
      _raise_if(EXCEPTION_INFINITY, 'Exponent overflow')
      sign.negative? ? N_INFINITY : INFINITY
    elsif e10 < MIN_E10
      _raise_if(EXCEPTION_UNDERFLOW, 'Exponent underflow')
      sign.negative? ? N_ZERO : P_ZERO
    else
      _alloc(nil, sign, coef, exp)
    end
  end

  def self._zero(sign) = sign.negative? ? N_ZERO : P_ZERO # :nodoc:
  def self._infinity(sign) = sign.negative? ? N_INFINITY : INFINITY # :nodoc:

  # A NaN of its own: the C version allocates one per result, and Array#include?
  # and Hash look at identity before they call ==.
  def self._nan = _alloc(:nan, 0, 0, 0) # :nodoc:

  def self._ndigits(n) # :nodoc:
    return n.to_s.length if n >= POW10[38]

    d = (n.bit_length * 1233) >> 12
    d += 1 if n >= POW10[d]
    d.zero? ? 1 : d
  end

  def self._pow10(n) = n < 40 ? POW10[n] : 10**n # :nodoc:

  # Rounds sign*coef*10**exp to a multiple of 10**pos. sticky: something
  # nonzero below coef's last digit was already dropped (inexact sqrt or
  # division), which the directed and half modes must know about.
  def self._round_to(sign, coef, exp, pos, mode, sticky: false) # :nodoc:
    return _make(sign, coef, exp) if exp >= pos && !sticky

    if exp >= pos
      quotient = coef * _pow10(exp - pos)
      rest = 0
      half = nil
    else
      unit = _pow10(pos - exp)
      quotient, rest = coef.divmod(unit)
      half = unit / 2
    end
    inexact = rest.positive? || sticky
    up = case mode
         when ROUND_DOWN then false
         when ROUND_UP then inexact
         when ROUND_HALF_UP then half && rest >= half
         when ROUND_HALF_DOWN then half && (rest > half || (rest == half && sticky))
         when ROUND_HALF_EVEN then half && (rest > half || (rest == half && (sticky || quotient.odd?)))
         when ROUND_CEILING then inexact && sign.positive?
         when ROUND_FLOOR then inexact && sign.negative?
         end
    quotient += 1 if up
    _make(sign, quotient, pos)
  end

  # To `digits` significant digits (VpLeftRound).
  def self._round_sig(sign, coef, exp, digits, mode, sticky: false) # :nodoc:
    return _zero(sign) if coef.zero?

    _round_to(sign, coef, exp, exp + _ndigits(coef) - digits, mode, sticky: sticky)
  end

  # BigDecimal.limit applied to a result, or `digits` when that is given.
  def self._limited(sign, coef, exp, digits = 0) = _rounded(sign, coef, exp, digits.zero? ? _limit : digits) # :nodoc:

  # To `digits` significant digits in the rounding mode; 0 means exact.
  def self._rounded(sign, coef, exp, digits) # :nodoc:
    return _make(sign, coef, exp) if digits.zero? || coef.zero?

    _round_sig(sign, coef, exp, digits, _rounding_mode)
  end

  def self._from_integer(n) = _make(n.negative? ? -1 : 1, n.abs, 0) # :nodoc:

  # Float: its shortest decimal form cut to 16 digits (digits == 0), or
  # rounded half-even to `digits` digits from the exact binary value.
  def self._from_float(f, digits, exception: true) # :nodoc:
    return _check(NAN) if f.nan?
    return _check(f.positive? ? INFINITY : N_INFINITY) if f.infinite?
    return (1 / f).negative? ? N_ZERO : P_ZERO if f.zero?

    if digits > DOUBLE_FIG
      return nil unless exception

      raise ArgumentError, 'precision too large.'
    end
    sign = f.negative? ? -1 : 1
    return _from_float_shortest(sign, f.abs) if digits.zero?

    figures, k = _dtoa2(f.abs, digits)
    _make(sign, figures.join.to_i, k + 1 - figures.size)
  end

  TENS = Array.new(23) { |i| Float("1e#{i}") }.freeze
  BIGTENS = [1e16, 1e32, 1e64, 1e128, 1e256].freeze
  private_constant :TENS, :BIGTENS

  # [digits, k]: the `ndigits` digits dtoa's mode 2 gives for d > 0, and
  # d's decimal exponent (d is 0.digits * 10**(k+1)). The C version converts
  # BigDecimal(float, n) with it, and it is not correctly rounded: a
  # floating-point shortcut decides "about one half" within an error window
  # and then rounds by the parity of the last digit. This repeats it step by
  # step on the same doubles (missing/dtoa.c).
  def self._dtoa2(d, ndigits) # :nodoc:
    fraction, exponent = Math.frexp(d)
    estimate = (((fraction * 2) - 1.5) * 0.289529654602168) + 0.1760912590558 + ((exponent - 1) * 0.301029995663981)
    k = estimate.to_i
    k -= 1 if estimate.negative? && estimate != k
    k_check = true
    if k.between?(0, 22)
      k -= 1 if d < TENS[k]
      k_check = false
    end
    half = false
    if ndigits <= 14
      quick = _dtoa2_quick(d, ndigits, k, k_check)
      return quick unless quick == :half

      half = true
    end
    return _dtoa2_integer(d, ndigits, k) if d == d.floor && k <= 14

    _dtoa2_exact(d, ndigits, half)
  end

  def self._dtoa2_quick(d, ilim, k, k_check) # :nodoc: rubocop:disable Metrics
    ieps = 2
    if k.positive?
      ds = TENS[k & 0xf]
      j = k >> 4
      if j.anybits?(0x10)
        j &= 0x0f
        d /= BIGTENS[4]
        ieps += 1
      end
      i = 0
      while j.positive?
        if j.odd?
          ieps += 1
          ds *= BIGTENS[i]
        end
        j >>= 1
        i += 1
      end
      d /= ds
    elsif k.negative?
      j = -k
      d *= TENS[j & 0xf]
      j >>= 4
      i = 0
      while j.positive?
        if j.odd?
          ieps += 1
          d *= BIGTENS[i]
        end
        j >>= 1
        i += 1
      end
    end
    if k_check && d < 1.0
      k -= 1
      d *= 10.0
      ieps += 1
    end
    eps = ((ieps * d) + 7.0) * (2.0**-52)
    eps *= TENS[ilim - 1]
    digits = []
    i = 1
    loop do
      digit = d.to_i
      d -= digit
      ilim = i if d.zero?
      digits << digit
      if i == ilim
        return _dtoa_bump(digits, k) if d > 0.5 + eps
        return [_dtoa_strip(digits), k] if d < 0.5 - eps
        return _dtoa_bump(digits, k) if digit.odd?

        return :half
      end
      i += 1
      d *= 10.0
    end
  end

  # An integer below 10**15, in doubles.
  def self._dtoa2_integer(d, ilim, k) # :nodoc:
    ds = TENS[k]
    digits = []
    i = 1
    loop do
      digit = (d / ds).to_i
      d -= digit * ds
      digits << digit
      break if d.zero?

      if i == ilim
        d += d
        return _dtoa_bump(digits, k) if d > ds || (d == ds && digit.odd?)

        break
      end
      i += 1
      d *= 10.0
    end
    [digits, k]
  end

  # The exact digits; with `half` set by the shortcut, a round-up only
  # happens on an odd last digit, and the nines it would carry through are
  # dropped either way.
  def self._dtoa2_exact(d, ilim, half) # :nodoc:
    exact = d.to_r
    k = Math.log10(d).floor
    k -= 1 while exact < Rational(10)**k
    k += 1 while exact >= Rational(10)**(k + 1)
    scaled = exact * (Rational(10)**(ilim - 1 - k))
    quotient = scaled.floor
    rest = scaled - quotient
    digits = quotient.digits.reverse
    return [_dtoa_strip(digits), k] if rest.zero?

    order = (rest * 2) <=> 1
    return [_dtoa_strip(digits), k] unless order.positive? || (order.zero? && digits.last.odd?)

    last = digits.size - 1
    last -= 1 while last.positive? && digits[last] == 9
    return [[1], k + 1] if digits[last] == 9

    digits = digits[0..last]
    digits[-1] += 1 if !half || digits[-1].odd?
    [digits, k]
  end

  # dtoa's bump_up: one more in the last digit, carrying through nines.
  def self._dtoa_bump(digits, k) # :nodoc:
    last = digits.size - 1
    last -= 1 while last.positive? && digits[last] == 9
    return [[1], k + 1] if digits[last] == 9

    [digits[0...last] + [digits[last] + 1], k]
  end

  def self._dtoa_strip(digits) # :nodoc:
    digits = digits.dup
    digits.pop while digits.size > 1 && digits.last.zero?
    digits
  end

  def self._from_float_shortest(sign, f) # :nodoc:
    mantissa, exponent = f.to_s.split('e')
    whole, fraction = mantissa.split('.')
    digits = whole + fraction.to_s
    e10 = whole.length + exponent.to_i
    stripped = digits.sub(/\A0+/, '')
    e10 -= digits.length - stripped.length
    digits = stripped.sub(/0+\z/, '')
    digits = digits[0, DOUBLE_FIG] if digits.length > DOUBLE_FIG
    _make(sign, digits.to_i, e10 - digits.length)
  end

  # Rational: numerator / denominator to `digits` digits (0: as `/`).
  def self._from_rational(r, digits) # :nodoc:
    _from_integer(r.numerator).div(r.denominator, digits)
  end

  # Kernel#BigDecimal.
  def self._convert(value, digits, exception) # :nodoc:
    unless digits.nil?
      digits = _to_int(digits)
      if digits.negative?
        return nil unless exception

        raise ArgumentError, 'negative precision'
      end
    end
    case value
    when nil, true, false
      return nil unless exception

      raise TypeError, "can't convert #{value.inspect} into BigDecimal"
    when BigDecimal then _check(value)
    when Integer then _from_integer(value)
    when Float then _from_float(value, digits || 0, exception: exception)
    when Rational
      if digits.nil?
        return nil unless exception

        raise ArgumentError, "can't omit precision for a Rational."
      end
      _from_rational(value, digits)
    when Complex
      unless _zero?(value.imaginary)
        return nil unless exception

        raise ArgumentError, 'Unable to make a BigDecimal from non-zero imaginary number'
      end
      _convert(value.real, digits, exception)
    when String then _from_string(value, exception)
    else
      string = value.respond_to?(:to_str) ? value.to_str : nil
      return _from_string(string, exception) if string.is_a?(String)
      return nil unless exception

      raise TypeError, "can't convert #{value.class} into BigDecimal"
    end
  end

  def self._zero?(x)
    case x
    when Integer then x.zero?
    when Rational then x.numerator.zero?
    else x == 0 # rubocop:disable Style/NumericPredicate -- any Numeric, as rb_equal(x, 0)
    end
  end
  private_class_method :_zero?

  def self._from_string(string, exception) # :nodoc:
    _ascii_compatible!(string)
    if string.include?("\0")
      return nil unless exception

      raise ArgumentError, 'string contains null byte'
    end
    value = _parse(string, true)
    if value.nil?
      return nil unless exception

      raise ArgumentError, "invalid value for BigDecimal(): \"#{string}\""
    end
    _check(value)
  end

  # String#to_d: reads as far as it can, 0 when nothing is a number.
  def self.interpret_loosely(string)
    string = _to_str(string)
    _ascii_compatible!(string)
    string = string[0, string.index("\0")] if string.include?("\0")
    _check(_parse(string, false))
  end

  def self._ascii_compatible!(string)
    return if string.encoding.ascii_compatible?

    raise Encoding::CompatibilityError, "ASCII incompatible encoding: #{string.encoding}"
  end
  private_class_method :_ascii_compatible!

  # The grammar of VpAlloc: spaces, Infinity/NaN, '#', sign, digits with
  # single underscores between them, '.', digits, e/E/d/D with a signed
  # exponent. strict (BigDecimal()) refuses anything else, nil for invalid;
  # loose (String#to_d) stops at the first character it cannot use.
  # Most strings are plain: sign, digits, a point, digits, an exponent. They
  # read the same either way, so the byte scanner only sees the others.
  SIMPLE_NUMBER = /\A[ \t\n\v\f\r]*([-+]?)(\d+)(?:\.(\d*))?(?:[eE]([-+]?\d+))?[ \t\n\v\f\r]*\z/
  private_constant :SIMPLE_NUMBER

  def self._parse(string, strict) # :nodoc:
    if string.ascii_only? && (match = SIMPLE_NUMBER.match(string))
      fraction = match[3] || ''
      return _parsed(match[1] == '-' ? -1 : 1, match[2] + fraction, fraction.length, match[4].to_i)
    end
    _scan(string, strict)
  end

  def self._scan(string, strict) # :nodoc: rubocop:disable Metrics
    s = string.b
    n = s.bytesize
    i = 0
    i += 1 while i < n && SPACE.include?(s.getbyte(i))
    SPECIAL_STRINGS.each do |text, kind, sign|
      next unless s.byteslice(i, text.bytesize) == text

      j = i + text.bytesize
      j += 1 while j < n && SPACE.include?(s.getbyte(j))
      return kind == :nan ? _nan : _infinity(sign) if j == n
    end
    i += 1 if s.getbyte(i) == 0x23 # '#'
    sign = 1
    if [0x2b, 0x2d].include?(s.getbyte(i))
      sign = -1 if s.getbyte(i) == 0x2d
      i += 1
    end
    invalid = strict ? nil : P_ZERO
    digit = ->(c) { c && c >= 0x30 && c <= 0x39 }

    digits = +''
    int_count = 0
    stop = nil
    loop do
      c = s.getbyte(i)
      break if c.nil? || (!strict && SPACE.include?(c))

      if c == 0x5f # '_'
        if int_count.positive?
          after = s.getbyte(i + 1)
          if after.nil? || SPACE.include?(after) || digit.call(after)
            i += 1
            next
          end
          break unless strict
        end
        return invalid
      end
      unless digit.call(c)
        stop = c
        break
      end
      digits << c
      int_count += 1
      i += 1
    end

    frac_count = 0
    exp_count = 0
    exp_seen = false
    exp_digits = +''
    exp_negative = false
    if stop
      if stop == 0x2e # '.'
        i += 1
        stop = nil
        loop do
          c = s.getbyte(i)
          break if c.nil? || (!strict && SPACE.include?(c))

          if c == 0x5f
            if frac_count.positive? && digit.call(s.getbyte(i + 1))
              i += 1
              next
            end
            break unless strict

            return nil
          end
          unless digit.call(c)
            stop = c
            break
          end
          digits << c
          frac_count += 1
          i += 1
        end
      end
      if stop && [0x65, 0x45, 0x64, 0x44].include?(stop) # e E d D
        exp_seen = true
        i += 1
        if [0x2b, 0x2d].include?(s.getbyte(i))
          exp_negative = s.getbyte(i) == 0x2d
          i += 1
        end
        stop = nil
        loop do
          c = s.getbyte(i)
          break if c.nil? || (!strict && SPACE.include?(c))

          if c == 0x5f
            if exp_count.positive? && digit.call(s.getbyte(i + 1))
              i += 1
              next
            end
            unless strict
              exp_seen = false if exp_count.zero?
              break
            end
            return nil
          end
          unless digit.call(c)
            stop = c
            break
          end
          exp_digits << c
          exp_count += 1
          i += 1
        end
      end
      if stop
        i += 1 while i < n && SPACE.include?(s.getbyte(i))
        return nil if strict && i < n
      end
    end
    return nil if strict && ((int_count.zero? && frac_count.zero?) || (exp_seen && exp_count.zero?))

    exponent = exp_digits.to_i
    _parsed(sign, digits, frac_count, exp_negative ? -exponent : exponent)
  end

  # sign * digits (a String, frac_count of them after the point) * 10**exponent.
  def self._parsed(sign, digits, frac_count, exponent) # :nodoc:
    coef = digits.to_i
    return _zero(sign) if coef.zero?

    exp = exponent - frac_count
    e10 = exp + _ndigits(coef)
    if e10 > MAX_E10
      _raise_if(EXCEPTION_INFINITY, 'exponent overflow')
      return _infinity(sign)
    end
    return _zero(sign) if e10 < MIN_E10

    _make(sign, coef, exp)
  end

  # CheckGetValue: a NaN or an infinity raises when its exception mode is on.
  def self._check(value) # :nodoc:
    return value if value.finite?

    kind, sign = value._parts
    if kind == :nan
      _raise_if(EXCEPTION_NaN, "Computation results in 'NaN' (Not a Number)")
    elsif kind == :inf
      _raise_if(EXCEPTION_INFINITY, "Computation results in '#{'-' if sign.negative?}Infinity'")
    end
    value
  end

  # VpIsDefOP's result for an operation that met NaN or an infinity.
  def self._special_result(value) # :nodoc:
    return value if value.finite?

    kind, sign = value._parts
    if kind == :nan
      _raise_if(EXCEPTION_NaN, "Computation results to 'NaN'")
    elsif kind == :inf
      _raise_if(EXCEPTION_INFINITY, "Computation results to '#{'-' if sign.negative?}Infinity'")
    end
    value
  end

  # NUM2INT: Integers, Floats truncated, anything with to_int.
  def self._num2int(value) # :nodoc:
    case value
    when Integer then value
    when Float
      raise FloatDomainError, value.to_s unless value.finite?

      value.truncate
    when nil then raise TypeError, 'no implicit conversion from nil to integer'
    else _to_int(value)
    end
  end

  # rb_to_int.
  def self._to_int(value) # :nodoc:
    return value if value.is_a?(Integer)
    return value.to_int if value.is_a?(Float) || (!value.nil? && value.respond_to?(:to_int))

    raise TypeError, "no implicit conversion of #{_type_name(value)} into Integer"
  end

  def self._to_str(value) # :nodoc:
    return value if value.is_a?(String)
    return value.to_str if value.respond_to?(:to_str)

    raise TypeError, "no implicit conversion of #{_type_name(value)} into String"
  end

  # How Ruby names a value in its conversion errors.
  def self._type_name(value) # :nodoc:
    case value
    when nil, true, false then value.inspect
    else value.class.to_s
    end
  end

  # rb_special_const_p decides between inspect and the class in coerce errors.
  def self._coerce_name(value) # :nodoc:
    case value
    when nil, true, false, Symbol, Integer, Float then value.inspect
    else value.class.to_s
    end
  end

  def self._load(string)
    string = _to_str(string)
    raise ArgumentError, 'string contains null byte' if string.include?("\0")

    colon = string.index(':')
    head = colon ? string[0, colon] : string
    raise TypeError, 'load failed: invalid character in the marshaled string' unless head.match?(/\A\d*\z/)

    rest = colon ? string[(colon + 1)..] : ''
    value = _parse(rest, true)
    raise ArgumentError, "invalid value for BigDecimal(): \"#{rest}\"" if value.nil?

    _check(value)
  end

  # ---- instances -----------------------------------------------------------

  def initialize(kind, sign, coef, exp) # rubocop:disable Lint/MissingSuper -- Numeric has nothing to set up
    @kind = kind # nil (finite), :nan or :inf
    @sign = sign
    @coef = coef
    @exp = exp
    freeze
  end

  def _parts = [@kind, @sign, @coef, @exp] # :nodoc:

  NAN = _alloc(:nan, 0, 0, 0)
  INFINITY = _alloc(:inf, 1, 0, 0)
  N_INFINITY = _alloc(:inf, -1, 0, 0)
  P_ZERO = _alloc(nil, 1, 0, 0)
  N_ZERO = _alloc(nil, -1, 0, 0)
  private_constant :N_INFINITY, :P_ZERO, :N_ZERO

  def nan? = @kind == :nan
  def finite? = @kind.nil?
  # infinite? and nonzero? answer nil, 1 or -1 and self or nil, as in C.
  # rubocop:disable Naming/PredicateMethod, Style/ReturnNilInPredicateMethodDefinition
  def infinite? = @kind == :inf ? @sign : nil
  def zero? = @kind.nil? && @coef.zero?
  def nonzero? = zero? ? nil : self
  # rubocop:enable Naming/PredicateMethod, Style/ReturnNilInPredicateMethodDefinition

  def sign
    case @kind
    when :nan then SIGN_NaN
    when :inf then @sign * 3
    else @coef.zero? ? @sign : @sign * 2
    end
  end

  def exponent = @kind || @coef.zero? ? 0 : _e10

  def precision
    return 0 if @kind || @coef.zero?

    e10 = _e10
    (e10.positive? ? e10 : 0) - (@exp.negative? ? @exp : 0)
  end

  def scale = @kind || @coef.zero? || @exp >= 0 ? 0 : -@exp
  def precision_scale = [precision, scale]
  def n_significant_digits = @kind || @coef.zero? ? 0 : BigDecimal._ndigits(@coef)

  def hash
    return [BigDecimal, @kind, @sign].hash if @kind || @coef.zero?

    [@sign, @coef, @exp].hash
  end

  def clone = self
  def dup = self
  def +@ = self

  def -@
    return BigDecimal._check(self) if @kind == :nan
    return BigDecimal._check(BigDecimal._infinity(-@sign)) if @kind

    BigDecimal._make(-@sign, @coef, @exp)
  end

  def abs
    return BigDecimal._check(self) if @kind == :nan
    return BigDecimal._check(INFINITY) if @kind

    BigDecimal._make(1, @coef, @exp)
  end

  # ---- conversion ----------------------------------------------------------

  def to_i
    _raise_unless_finite
    return 0 if _e10 <= 0

    value = @exp >= 0 ? @coef * (10**@exp) : @coef / BigDecimal._pow10(-@exp)
    raise FloatDomainError, 'Infinity' if value.is_a?(Float)

    @sign.negative? ? -value : value
  end
  alias to_int to_i

  def to_r
    _raise_unless_finite
    value = @exp >= 0 ? Rational(@coef * (10**@exp), 1) : Rational(@coef, BigDecimal._pow10(-@exp))
    @sign.negative? ? -value : value
  end

  def to_f
    case @kind
    when :nan then return Float::NAN
    when :inf then return @sign * Float::INFINITY
    end
    return @sign.negative? ? -0.0 : 0.0 if @coef.zero? # rubocop:disable Lint/DuplicateBranch, Style/IdenticalConditionalBranches -- -0.0 is not 0.0

    words = 9 * _word_exponent
    return _float_overflow if words > 317
    return _float_underflow if words < -322

    f = "#{'-' if @sign.negative?}0.#{@coef}e#{_e10}".to_f
    return _float_underflow if f.zero?
    return _float_overflow if f.infinite?

    f
  end

  def to_s(*args)
    raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0..1)" if args.size > 1

    plain = false
    plus = nil
    group = 0
    unless args.empty?
      format = args[0]
      if format.is_a?(String)
        raise ArgumentError, 'string contains null byte' if format.include?("\0")

        bytes = format.bytes
        if [0x20, 0x2b].include?(bytes[0])
          plus = bytes.shift == 0x20 ? ' ' : '+'
        end
        bytes.each do |c|
          next if SPACE.include?(c)

          unless c.between?(0x30, 0x39)
            plain = [0x46, 0x66].include?(c)
            break
          end
          group = (group * 10) + c - 0x30
        end
      else
        group = BigDecimal._num2int(format)
        raise ArgumentError, 'argument must be positive' unless group.positive?
      end
    end
    special = _special_string(plus)
    return special if special

    prefix = @sign.negative? ? '-' : plus.to_s
    plain ? prefix + _plain_string(group) : prefix + _exponent_string(group)
  end

  def inspect = to_s

  def split
    case @kind
    when :nan then [0, 'NaN', 10, 0]
    when :inf then [@sign, 'Infinity', 10, 0]
    else [@sign, @coef.zero? ? '0' : @coef.to_s, 10, exponent]
    end
  end

  def _dump(_level = nil) = "#{_words * 9}:#{self}"

  def coerce(other)
    value = _operand(other, 0)
    raise TypeError, "#{BigDecimal._coerce_name(other)} can't be coerced into BigDecimal" if value.nil?

    [BigDecimal._check(value), self]
  end

  # self * 10**n, as the C version's internal helper.
  def _decimal_shift(n)
    shift = BigDecimal._to_int(n)
    return BigDecimal._check(self) if @kind || @coef.zero? || shift.zero?

    BigDecimal._make(@sign, @coef, @exp + shift)
  end

  # ---- arithmetic ----------------------------------------------------------

  def +(other) = _add(other, 1, 0, :+)
  def -(other) = _add(other, -1, 0, :-)
  def add(other, digits) = _add(other, 1, _precision_arg(digits), nil)
  def sub(other, digits) = _add(other, -1, _precision_arg(digits), nil)
  def *(other) = _mult(other, 0, :*)
  def mult(other, digits) = _mult(other, _precision_arg(digits), nil)
  def /(other) = _div(other, 0, :/)

  def quo(value, *digits)
    raise ArgumentError, "wrong number of arguments (given #{digits.size + 1}, expected 1..2)" if digits.size > 1

    n = digits.empty? ? 0 : _precision_arg(digits[0])
    n.positive? ? _div(value, n, nil) : _div(value, 0, :/)
  end

  # Without digits an Integer, rounded down, like Float#div; with digits a
  # BigDecimal of that many digits, digits == 0 meaning as `/`.
  def div(other, digits = nil)
    if digits.nil?
      quotient, = _divmod(other, false, :div)
      return quotient.is_a?(BigDecimal) ? BigDecimal._check(quotient).to_i : quotient
    end
    _div(other, _precision_arg(digits), nil)
  end

  def %(other)
    result = _divmod(other, false, :%)
    result.is_a?(Array) ? BigDecimal._check(result[1]) : result
  end
  alias modulo %

  def remainder(other)
    result = _divmod(other, true, :remainder)
    result.is_a?(Array) ? BigDecimal._check(result[1]) : result
  end

  def divmod(other)
    result = _divmod(other, false, :divmod)
    return result unless result.is_a?(Array) && result[0].is_a?(BigDecimal)

    [BigDecimal._check(result[0]).to_i, BigDecimal._check(result[1])]
  end

  # ---- rounding ------------------------------------------------------------

  # round -> Integer; round(n) -> Integer for n < 1, else BigDecimal;
  # round(n, mode) and round(half: ...) -> BigDecimal.
  def round(*args)
    raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0..2)" if args.size > 2

    mode = BigDecimal._rounding_mode
    position = 0
    integer = false
    case args.size
    when 0 then integer = true
    when 1
      if args[0].is_a?(Hash)
        mode = BigDecimal._half_option(args[0])
      else
        position = BigDecimal._num2int(args[0])
        integer = position < 1
      end
    when 2
      position = BigDecimal._num2int(args[0])
      mode = args[1].is_a?(Hash) ? BigDecimal._half_option(args[1]) : BigDecimal._rounding_mode_of(args[1])
    end
    rounded = BigDecimal._check(_round_at(position, mode))
    integer ? rounded.to_i : rounded
  end

  def truncate(*args) = _round_method(args, ROUND_DOWN)
  def floor(*args) = _round_method(args, ROUND_FLOOR)
  def ceil(*args) = _round_method(args, ROUND_CEILING)
  def fix = BigDecimal._check(_round_at(0, ROUND_DOWN))

  def frac
    return BigDecimal._check(self) if @kind || @coef.zero?
    return BigDecimal._zero(@sign) if @exp >= 0
    return self if _e10 <= 0

    BigDecimal._make(@sign, @coef % BigDecimal._pow10(-@exp), @exp)
  end

  # ---- comparison ----------------------------------------------------------

  def <=>(other)
    return _compare_with(other, :<=>) unless other.is_a?(BigDecimal)

    _compare(other)
  end

  def ==(other)
    return _compare_with(other, :==) unless other.is_a?(BigDecimal)

    _compare(other) == 0 # rubocop:disable Style/NumericPredicate -- nil for NaN
  end
  alias === ==
  alias eql? ==

  def <(other)
    return _compare_with(other, :<) unless other.is_a?(BigDecimal)

    (order = _compare(other)) ? order.negative? : false
  end

  def <=(other)
    return _compare_with(other, :<=) unless other.is_a?(BigDecimal)

    (order = _compare(other)) ? order <= 0 : false
  end

  def >(other)
    return _compare_with(other, :>) unless other.is_a?(BigDecimal)

    (order = _compare(other)) ? order.positive? : false
  end

  def >=(other)
    return _compare_with(other, :>=) unless other.is_a?(BigDecimal)

    (order = _compare(other)) ? order >= 0 : false
  end

  protected

  def _kind = @kind
  def _sign = @sign
  def _coef = @coef
  def _exp = @exp

  # -1, 0, 1, or nil when either is NaN (VpComp).
  def _compare(other)
    kind = other._kind
    if @kind.nil? && kind.nil?
      cb = other._coef
      a = @coef.zero? ? 0 : @sign
      b = cb.zero? ? 0 : other._sign
      return a <=> b if a != b
      return 0 if a.zero?

      magnitude = _magnitude_compare(cb, other._exp)
      return a.positive? ? magnitude : -magnitude
    end
    return nil if @kind == :nan || kind == :nan
    return kind ? @sign <=> other._sign : @sign if @kind

    -other._sign
  end

  # |self| <=> cb * 10**eb, both nonzero.
  def _magnitude_compare(cb, eb)
    return @coef <=> cb if @exp == eb

    na = BigDecimal._ndigits(@coef)
    nb = BigDecimal._ndigits(cb)
    return (@exp + na) <=> (eb + nb) if @exp + na != eb + nb

    if @exp > eb
      (@coef * BigDecimal._pow10(@exp - eb)) <=> cb
    else
      @coef <=> (cb * BigDecimal._pow10(eb - @exp))
    end
  end

  # Decimal exponent: self is 0.ddd * 10**_e10.
  def _e10 = @exp + BigDecimal._ndigits(@coef)

  # The C version's word exponent: 0.www * BASE**n.
  def _word_exponent = (_e10 + 8).div(9)

  # How many 9-digit words the C version stores the digits in.
  def _words
    return 1 if @kind || @coef.zero?

    (@exp + BigDecimal._ndigits(@coef) - 1).div(9) - @exp.div(9) + 1
  end

  private

  def _raise_unless_finite
    case @kind
    when :nan then raise FloatDomainError, "Computation results in 'NaN' (Not a Number)"
    when :inf then raise FloatDomainError, "Computation results in '#{'-' if @sign.negative?}Infinity'"
    end
  end

  def _float_overflow
    BigDecimal._raise_if(EXCEPTION_OVERFLOW, 'BigDecimal to Float conversion')
    @sign.negative? ? -Float::INFINITY : Float::INFINITY
  end

  def _float_underflow
    BigDecimal._raise_if(EXCEPTION_UNDERFLOW, 'BigDecimal to Float conversion')
    @sign.negative? ? -0.0 : 0.0 # rubocop:disable Lint/DuplicateBranch, Style/IdenticalConditionalBranches -- -0.0 is not 0.0
  end

  def _special_string(plus)
    case @kind
    when :nan then 'NaN'
    when :inf then @sign.negative? ? '-Infinity' : "#{plus}Infinity"
    else
      return unless @coef.zero?

      @sign.negative? ? '-0.0' : "#{plus}0.0"
    end
  end

  def _exponent_string(group)
    digits = @coef.to_s
    digits = digits.scan(/.{1,#{group}}/).join(' ') if group.positive?
    "0.#{digits}e#{_e10}"
  end

  def _plain_string(group)
    digits = @coef.to_s
    e10 = @exp + digits.length
    if @exp >= 0
      whole = digits + ('0' * @exp)
      fraction = ''
    elsif e10.positive?
      whole = digits[0, e10]
      fraction = digits[e10..]
    else
      whole = '0'
      fraction = ('0' * -e10) + digits
    end
    if group.positive?
      whole = whole.reverse.scan(/.{1,#{group}}/).join(' ').reverse if whole != '0'
      fraction = fraction.scan(/.{1,#{group}}/).join(' ')
    end
    "#{whole}.#{fraction.empty? ? '0' : fraction}"
  end

  # check_int_precision: an Integer >= 0.
  def _precision_arg(digits)
    n = BigDecimal._num2int(digits)
    raise ArgumentError, 'negative precision' if n.negative?

    n
  end

  # GetCoercePrec: how many digits a Rational operand is converted with.
  def _coerce_prec(prec)
    prec = _words * 9 if prec.zero?
    [prec, 2 * DOUBLE_FIG].max
  end

  # The other operand as a BigDecimal, or nil when it is not one of the four
  # types BigDecimal converts itself. prec is the operation's precision
  # argument, which decides a Rational's digits.
  def _operand(other, prec)
    case other
    when BigDecimal then other
    when Integer then BigDecimal._from_integer(other)
    when Float then BigDecimal._from_float(other, 0)
    when Rational then BigDecimal._from_rational(other, _coerce_prec(prec))
    end
  end

  # rb_num_coerce_bin: other.coerce(self), then the operator on the pair.
  def _coerce_bin(other, operator)
    unless other.respond_to?(:coerce)
      raise TypeError, "#{BigDecimal._coerce_name(other)} can't be coerced into BigDecimal"
    end

    pair = other.coerce(self)
    raise TypeError, 'coerce must return [x, y]' unless pair.is_a?(Array) && pair.size == 2

    pair[0].public_send(operator, pair[1])
  end

  def _operand!(other, prec, operator)
    value = _operand(other, prec)
    return value if value
    return nil if operator

    raise TypeError, "#{BigDecimal._coerce_name(other)} can't be coerced into BigDecimal"
  end

  def _add(other, op, prec, operator)
    b = _operand!(other, prec, operator)
    return _coerce_bin(other, operator) if b.nil?
    return BigDecimal._check(self) if @kind == :nan
    return BigDecimal._check(b) if b._kind == :nan

    if @kind || b._kind
      result = if @kind && b._kind
                 @sign == op * b._sign ? self : BigDecimal._nan
               elsif @kind
                 self
               else
                 BigDecimal._infinity(op * b._sign)
               end
      return BigDecimal._check(BigDecimal._special_result(result))
    end

    _add_finite(b._coef, op * b._sign, b._exp, prec)
  end

  def _add_finite(cb, sb, eb, prec)
    digits = prec.zero? ? BigDecimal._limit : prec
    ca = @coef
    sa = @sign
    ea = @exp
    if ca.zero?
      return BigDecimal._zero(sa.negative? && sb.negative? ? -1 : 1) if cb.zero?

      return BigDecimal._rounded(sb, cb, eb, digits)
    end
    return BigDecimal._rounded(sa, ca, ea, digits) if cb.zero?

    if digits.positive?
      # An operand far below the other's last digit and the rounding
      # position only decides the rounding: shrink it to one sticky digit.
      ha = ea + BigDecimal._ndigits(ca)
      hb = eb + BigDecimal._ndigits(cb)
      low_a = [ea, ha - 1 - digits].min
      low_b = [eb, hb - 1 - digits].min
      if hb <= low_a - 1
        cb = 1
        eb = low_a - 2
      elsif ha <= low_b - 1
        ca = 1
        ea = low_b - 2
      end
    end
    if ea < eb
      e = ea
      sum = (sa * ca) + (sb * cb * BigDecimal._pow10(eb - ea))
    else
      e = eb
      sum = (sa * ca * BigDecimal._pow10(ea - eb)) + (sb * cb)
    end
    return P_ZERO if sum.zero?

    BigDecimal._rounded(sum.negative? ? -1 : 1, sum.abs, e, digits)
  end

  def _mult(other, prec, operator)
    b = _operand!(other, prec, operator)
    return _coerce_bin(other, operator) if b.nil?

    if @kind == :nan || b._kind == :nan
      return BigDecimal._check(BigDecimal._special_result(BigDecimal._nan))
    elsif @kind || b._kind
      zero = (@kind.nil? && @coef.zero?) || (b._kind.nil? && b._coef.zero?)
      result = zero ? BigDecimal._nan : BigDecimal._infinity(@sign * b._sign)
      return BigDecimal._check(BigDecimal._special_result(result))
    end

    sign = @sign * b._sign
    return BigDecimal._zero(sign) if @coef.zero? || b._coef.zero?

    coef = @coef * b._coef
    exp = @exp + b._exp
    return BigDecimal._round_sig(sign, coef, exp, prec, BigDecimal._rounding_mode) if prec.positive?

    BigDecimal._limited(sign, coef, exp)
  end

  def _div(other, digits, operator)
    b = _operand!(other, digits, operator)
    return _coerce_bin(other, operator) if b.nil?

    if digits.zero?
      digits = [precision, b.precision].max + DOUBLE_FIG
      digits = 2 * DOUBLE_FIG if digits < 2 * DOUBLE_FIG
      limit = BigDecimal._limit
      digits = limit if limit.positive? && limit < digits
    end
    BigDecimal._check(_quotient(b, digits))
  end

  # VpDivd plus the rounding of BigDecimal_div2.
  def _quotient(b, digits)
    sign = @sign * b._sign
    if @kind == :nan || b._kind == :nan
      return BigDecimal._special_result(BigDecimal._nan)
    elsif @kind
      return BigDecimal._special_result(b._kind ? BigDecimal._nan : BigDecimal._infinity(sign))
    elsif b._kind
      # The C version reports this zero as '-Infinity', whatever its sign.
      BigDecimal._raise_if(EXCEPTION_INFINITY, "Computation results to '-Infinity'")
      return BigDecimal._zero(sign)
    elsif b._coef.zero?
      if @coef.zero?
        BigDecimal._raise_if(EXCEPTION_NaN, "Computation results to 'NaN'")
        return BigDecimal._nan
      end
      BigDecimal._raise_if(EXCEPTION_ZERODIVIDE, 'Divide by zero')
      return BigDecimal._infinity(sign)
    end
    return BigDecimal._zero(sign) if @coef.zero?

    # The C version divides into roomof(digits + 18, 9) words, from word
    # exponent a - b + 1 down, and rounds from those words alone; a
    # remainder only adds one to word roomof(digits, 9) when that word is
    # 0 or 500000000. When the first word comes out 0, a single digit may
    # remain past the rounding position, and a quotient just above a tie
    # rounds as the tie in the half modes. Kept, to round as C does.
    words = (digits + 26) / 9
    low = 9 * (_word_exponent - b._word_exponent + 1 - words)
    shift = @exp - b._exp - low
    quotient, rest = if shift >= 0
                       (@coef * BigDecimal._pow10(shift)).divmod(b._coef)
                     else
                       @coef.divmod(b._coef * BigDecimal._pow10(-shift))
                     end
    if rest.positive?
      below = ((BigDecimal._ndigits(quotient) + 8) / 9) - 1 - ((digits + 8) / 9)
      if below >= 0
        word = (quotient / BigDecimal._pow10(9 * below)) % BASE
        quotient += BigDecimal._pow10(9 * below) if word.zero? || word == BASE / 2
      else
        quotient = (quotient * BigDecimal._pow10(-9 * below)) + 1
        low += 9 * below
      end
    end
    BigDecimal._round_sig(sign, quotient, low, digits, BigDecimal._rounding_mode)
  end

  # [div, mod] as BigDecimals (BigDecimal_DoDivmod), or what the coerced
  # operation returned when other is not a number BigDecimal converts.
  def _divmod(other, truncate, operator)
    b = _operand(other, 0)
    return _coerce_bin(other, operator) if b.nil?

    return [NAN, NAN] if @kind == :nan || b._kind == :nan || (@kind && b._kind)
    raise ZeroDivisionError, 'divided by 0' if b._kind.nil? && b._coef.zero?
    return [BigDecimal._infinity(@sign * b._sign), NAN] if @kind
    return [P_ZERO, self] if @coef.zero?

    if b._kind
      return [BigDecimal._from_integer(-1), b] if !truncate && (@sign * b._sign).negative?

      return [P_ZERO, self]
    end
    e = [@exp, b._exp].min
    a = @sign * @coef * BigDecimal._pow10(@exp - e)
    d = b._sign * b._coef * BigDecimal._pow10(b._exp - e)
    quotient = a.abs / d.abs
    quotient = -quotient if a.negative? ^ d.negative?
    rest = a - (quotient * d)
    if !truncate && !rest.zero? && (a.negative? ^ d.negative?)
      quotient -= 1
      rest += d
    end
    [BigDecimal._from_integer(quotient), BigDecimal._make(rest.negative? ? -1 : 1, rest.abs, e)]
  end

  # VpActiveRound: to `position` digits after the point (left for negative).
  def _round_at(position, mode)
    return self if @kind || @coef.zero?
    # The C version zeroes ROUND_UP when the position lies a whole word
    # left of the number, where it should give one unit.
    return BigDecimal._zero(@sign) if mode == ROUND_UP && (position + (9 * _word_exponent)).negative?

    BigDecimal._round_to(@sign, @coef, @exp, -position, mode)
  end

  def _round_method(args, mode)
    raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0..1)" if args.size > 1

    rounded = _round_at(args.empty? ? 0 : BigDecimal._num2int(args[0]), mode)
    args.empty? ? BigDecimal._check(rounded).to_i : BigDecimal._check(rounded)
  end

  def _compare_with(other, operator)
    b = _operand(other, 0)
    return _coerce_compare(other, operator) if b.nil?

    order = _compare(b)
    return operator == :<=> ? nil : false if order.nil?

    case operator
    when :<=> then order
    when :== then order.zero?
    when :< then order.negative?
    when :<= then order <= 0
    when :> then order.positive?
    when :>= then order >= 0
    end
  end

  # rb_num_coerce_cmp for <=> and ==, rb_num_coerce_relop for the others.
  def _coerce_compare(other, operator)
    pair = other.respond_to?(:coerce) ? other.coerce(self) : nil
    unless pair.nil?
      raise TypeError, 'coerce must return [x, y]' unless pair.is_a?(Array) && pair.size == 2

      result = pair[0].public_send(operator, pair[1])
      return result if operator == :<=>
      return result ? true : false if operator == :==
      return result unless result.nil?
    end
    return nil if operator == :<=>
    return false if operator == :==

    raise ArgumentError, "comparison of BigDecimal with #{BigDecimal._coerce_name(other)} failed"
  end
end

# Kernel#BigDecimal, the conversion function.
module Kernel
  def BigDecimal(value, *digits, exception: true) # rubocop:disable Naming/MethodName
    unless exception == true || exception == false # rubocop:disable Style/MultipleComparison -- no Array per call
      raise ArgumentError, "expected true or false as exception: #{exception.inspect}"
    end
    raise ArgumentError, "wrong number of arguments (given #{digits.size + 1}, expected 1..2)" if digits.size > 1

    BigDecimal._convert(value, digits.empty? ? nil : digits[0], exception)
  end
  module_function :BigDecimal
end
