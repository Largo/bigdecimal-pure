# frozen_string_literal: true

require_relative 'calc'

module BigDecimalPure
  # Argument handling shared by BigMath, power and sqrt, with the messages of
  # bigdecimal 4.x.
  module Calc # :nodoc: all
    module_function

    def precision(prec, name, accept_zero: false)
      unless prec.is_a?(Integer)
        original = prec
        raise TypeError, "no implicit conversion of #{original.class} into Integer" unless prec.respond_to?(:to_int)

        prec = prec.to_int
        raise TypeError, "can't convert #{original.class} to Integer" unless prec.is_a?(Integer)
      end
      if accept_zero
        raise ArgumentError, "Negative precision for #{name}" if prec.negative?
      elsif prec <= 0
        raise ArgumentError, "Zero or negative precision for #{name}"
      end
      prec
    end

    def coerce(x, prec, _name)
      case x
      when BigDecimal then x
      when Integer, Float then BigDecimal(x, 0)
      when Rational then BigDecimal(x, [prec, 32].max)
      else raise ArgumentError, "#{x.inspect} can't be coerced into BigDecimal"
      end
    end

    def nan_result
      BigDecimal._raise_if(BigDecimal::EXCEPTION_NaN, "Computation results to 'NaN'")
      BigDecimal::NAN
    end

    def infinity_result
      BigDecimal._raise_if(BigDecimal::EXCEPTION_INFINITY, "Computation results in 'Infinity'")
      BigDecimal::INFINITY
    end

    def underflow_result
      BigDecimal._raise_if(BigDecimal::EXCEPTION_UNDERFLOW, 'Exponent underflow')
      BigDecimal(0)
    end

    # A positive value below every digit a result of w digits can show:
    # 1.sub(tiny, prec) rounds like 1 minus anything that small.
    def tiny(w) = BigDecimal._make(1, 1, -(w + 10))

    # atan of any finite x.
    def signed_atan(x, w)
      return x if x.zero?

      x.negative? ? -atan(-x, w) : atan(x, w)
    end

    # asin of a finite x with 0 < |x| < 1: atan(x / sqrt(1 - x**2)).
    def asin(x, w)
      signed_atan(x.div(sqrt(minus(one, times(x, x)), w + 2), w + 2), w)
    end

    def log_base(x, prec, base, name)
      prec = precision(prec, name)
      x = coerce(x, prec, name)
      return nan_result if x.nan?
      return infinity_result if x.infinite? == 1

      # As bigdecimal 4.x: round half up well below the precision first, so
      # that log10(10**n) is n in every rounding mode.
      w = prec + 24
      v = BigMath.log(x, w).div(BigMath.log(BigDecimal(base), w), w)
      v = v.round(prec + 16 - (v.exponent.negative? ? v.exponent : 0), BigDecimal::ROUND_HALF_UP)
      v.mult(1, prec)
    end

    # gamma and lgamma raise for NaN and the infinities, whatever the mode.
    def gamma_finite!(x)
      raise FloatDomainError, "Computation results in 'NaN' (Not a Number)" if x.nan?
      raise FloatDomainError, "Computation results in 'Infinity'" if x.infinite?
    end

    FACTORIAL_LIMIT = 3000

    # Gamma(x) for a finite x >= 0.5, to w digits.
    def gamma_positive(x, w)
      return BigDecimal(factorial(x.to_i - 1)) if x.frac.zero? && x <= FACTORIAL_LIMIT

      exp(lgamma_positive(x, w + 2), w)
    end

    # ln |Gamma(x)| and its sign for a finite x < 0.5 that is not an
    # integer, by the reflection formula
    #   ln |Gamma(x)| = ln pi - ln |sin(pi x)| - ln Gamma(1 - x),
    # with as many digits after the point as w significant digits need.
    def lgamma_reflected(x, w)
      digits = w
      loop do
        s = digits + 5
        sine = sin_pi(x, s + 5)
        log_sine = log(sine.abs, s + 5 + ndigits((3 * sine.exponent.abs) + 1))
        log_pi = log(pi_decimal(s + 5), s + 5)
        value = fixed(log_pi, s) - fixed(log_sine, s) - fixed(lgamma_positive(minus(one, x), s), s)
        result = decimal(value, s)
        return [result, sine.positive? ? 1 : -1] if !value.zero? && digits + result.exponent >= w

        digits += w - (digits + (value.zero? ? -digits : result.exponent)) + 5
      end
    end
  end
end

# power, ** and sqrt, which need the arithmetic of BigDecimalPure::Calc.
class BigDecimal
  def **(other)
    case other
    when BigDecimal, Integer, Float, Rational then power(other)
    when nil then raise TypeError, 'wrong argument type NilClass'
    else
      x, y = other.coerce(self)
      x**y
    end
  end

  # self ** y to prec digits; prec == 0 with an Integer y and no limit is
  # exact, as in bigdecimal 4.x, and so are the other rules below.
  def power(y, prec = 0)
    calc = BigDecimalPure::Calc
    prec = calc.precision(prec, :power, accept_zero: true)
    x = self
    y = calc.coerce(y, prec.nonzero? || n_significant_digits, :power)
    return calc.nan_result if x.nan? || y.nan?
    return BigDecimal(1) if y.zero?

    if y.infinite?
      if x.negative?
        return BigDecimal(0) if x < -1 && y.negative?
        return BigDecimal(0) if x > -1 && y.positive?

        raise Math::DomainError, 'Result undefined for negative base raised to infinite power'
      elsif x < 1
        return y.positive? ? BigDecimal(0) : calc.infinity_result
      elsif x == 1
        return BigDecimal(1)
      else
        return y.positive? ? calc.infinity_result : BigDecimal(0)
      end
    end
    if x.infinite? && y.negative?
      odd = x.negative? && y.frac.zero? && (y % 2).nonzero? # BigDecimal has no odd?
      return odd ? -BigDecimal(0) : BigDecimal(0)
    end
    if x.zero?
      return BigDecimal(0) if y.positive?
      return -calc.infinity_result if y.frac.zero? && (y % 2).nonzero? && x.sign == SIGN_NEGATIVE_ZERO

      return calc.infinity_result
    end
    if x.negative?
      raise Math::DomainError, 'Computation results in complex number' unless y.frac.zero?

      result = (-x).power(y, prec)
      return (y % 2).zero? ? result : -result
    end
    return BigDecimal(1) if x == 1

    limit = BigDecimal.limit
    integral = y.frac.zero?
    return _power_exact(y.to_i) if integral && prec.zero? && limit.zero?

    digits = prec.nonzero? || ([x.n_significant_digits, y.n_significant_digits, DOUBLE_FIG].max + DOUBLE_FIG)
    digits = [digits, limit].min if prec.zero? && limit.nonzero?
    work = digits + DOUBLE_FIG
    if y.negative?
      inverse = x.power(-y, work)
      return BigDecimal(0) if inverse.infinite?
      return calc.infinity_result if inverse.zero?

      return BigDecimal(1).div(inverse, digits)
    end
    if integral && y.exponent < (Math.log(digits) * 5) + 20
      return _power_by_squaring(y.to_i, work + y.exponent).mult(1, digits)
    end

    if x > 1 && x.finite?
      log_exponent = x < 2 ? (x - 1).exponent : Math.log10(x.exponent).round
      work += [y.exponent + log_exponent, 0].max
    end
    BigMath.exp(BigMath.log(x, work).mult(y, work), digits)
  end

  # Square root to prec digits, prec == 0 meaning the significant digits
  # plus 16 (at most BigDecimal.limit). Exact results stay exact in every
  # rounding mode: the root is an Integer square root.
  def sqrt(prec)
    calc = BigDecimalPure::Calc
    prec = calc.precision(prec, :sqrt, accept_zero: true)
    return calc.infinity_result if infinite? == 1
    raise FloatDomainError, 'sqrt of negative value' if negative?
    raise FloatDomainError, "sqrt of 'NaN'(Not a Number)" if nan?
    return self if zero?

    if prec.zero?
      limit = BigDecimal.limit
      prec = n_significant_digits + DOUBLE_FIG
      prec = [limit, prec].min if limit.nonzero?
    end
    root, exp, exact = calc.sqrt_digits(self, prec + 1)
    BigDecimal._round_sig(1, root, exp, prec, BigDecimal._rounding_mode, sticky: !exact)
  end

  private

  # self ** n exactly, for a finite self > 0; Infinity or 0 when the result
  # leaves the exponent range.
  def _power_exact(n)
    return BigDecimal(1) * self if infinite? # Infinity ** n for n > 0

    negative = n.negative?
    n = n.abs
    size = _e10 + Math.log10("0.#{@coef.to_s[0, 17]}".to_f)
    if size.nonzero? && n * size.abs > 9e18
      grows = size.positive? ^ negative
      return grows ? BigDecimalPure::Calc.infinity_result : BigDecimal(0)
    end
    coef = 1
    base = @coef
    k = n
    while k.positive?
      coef *= base if k.odd?
      k >>= 1
      base *= base if k.positive?
    end
    result = BigDecimal._make(1, coef, @exp * n)
    negative ? BigDecimal(1) / result : result
  end

  def _power_by_squaring(n, digits)
    result = BigDecimal(1)
    base = self
    loop do
      result = result.mult(base, digits) if n.odd?
      n >>= 1
      break if n.zero?

      base = base.mult(base, digits)
    end
    result
  end
end

# BigMath of bigdecimal 4.x, computed to the precision asked for.
module BigMath
  CALC = BigDecimalPure::Calc
  private_constant :CALC

  module_function

  def exp(x, prec)
    prec = CALC.precision(prec, :exp)
    x = CALC.coerce(x, prec, :exp)
    return CALC.nan_result if x.nan?

    if x.infinite? || x.exponent >= 21
      return CALC.infinity_result if x.positive?
      return BigDecimal(0) if x.infinite?

      return CALC.underflow_result
    end
    return BigDecimal(1) if x.zero?

    CALC.exp(x, prec + CALC::GUARD).mult(1, prec)
  end

  def log(x, prec)
    prec = CALC.precision(prec, :log)
    raise Math::DomainError, 'Complex argument for BigMath.log' if x.is_a?(Complex)

    x = CALC.coerce(x, prec, :log)
    return CALC.nan_result if x.nan?
    raise Math::DomainError, 'Negative argument for log' if x.negative?
    return -CALC.infinity_result if x.zero?
    return CALC.infinity_result if x.infinite?
    return BigDecimal(0) if x == 1

    CALC.log(x, prec + CALC::GUARD).mult(1, prec)
  end

  def sqrt(x, prec)
    prec = CALC.precision(prec, :sqrt)
    CALC.coerce(x, prec, :sqrt).sqrt(prec)
  end

  def cbrt(x, prec)
    prec = CALC.precision(prec, :cbrt)
    x = CALC.coerce(x, prec, :cbrt)
    return CALC.nan_result if x.nan?
    return CALC.infinity_result * x.infinite? if x.infinite?
    return BigDecimal(0) if x.zero?

    root, exp, exact = CALC.cbrt_digits(x.abs, prec + 1)
    BigDecimal._round_sig(x.negative? ? -1 : 1, root, exp, prec, BigDecimal._rounding_mode, sticky: !exact)
  end

  def hypot(x, y, prec)
    prec = CALC.precision(prec, :hypot)
    x = CALC.coerce(x, prec, :hypot)
    y = CALC.coerce(y, prec, :hypot)
    return CALC.nan_result if x.nan? || y.nan?
    return CALC.infinity_result if x.infinite? || y.infinite?

    CALC.plus(CALC.times(x, x), CALC.times(y, y)).sqrt(prec)
  end

  def sin(x, prec)
    prec = CALC.precision(prec, :sin)
    x = CALC.coerce(x, prec, :sin)
    return CALC.nan_result if x.infinite? || x.nan?
    return BigDecimal(0) if x.zero?

    CALC.sin_cos(x, prec + CALC::GUARD, false).mult(1, prec)
  end

  def cos(x, prec)
    prec = CALC.precision(prec, :cos)
    x = CALC.coerce(x, prec, :cos)
    return CALC.nan_result if x.infinite? || x.nan?
    return BigDecimal(1) if x.zero?

    CALC.sin_cos(x, prec + CALC::GUARD, true).mult(1, prec)
  end

  def tan(x, prec)
    prec = CALC.precision(prec, :tan)
    x = CALC.coerce(x, prec + 16, :tan)
    return CALC.nan_result if x.infinite? || x.nan?
    return BigDecimal(0) if x.zero?

    CALC.tan(x, prec + CALC::GUARD).mult(1, prec)
  end

  def asin(x, prec)
    prec = CALC.precision(prec, :asin)
    x = CALC.coerce(x, prec, :asin)
    raise Math::DomainError, 'Out of domain argument for asin' if x < -1 || x > 1
    return CALC.nan_result if x.nan?
    return x.mult(1, prec) if x.zero?

    w = prec + CALC::GUARD
    return CALC.pi_decimal(w).div(x.positive? ? 2 : -2, prec) if x.abs == 1

    CALC.asin(x, w).mult(1, prec)
  end

  def acos(x, prec)
    prec = CALC.precision(prec, :acos)
    x = CALC.coerce(x, prec, :acos)
    raise Math::DomainError, 'Out of domain argument for acos' if x < -1 || x > 1
    return CALC.nan_result if x.nan?

    w = prec + CALC::GUARD
    half_pi = CALC.pi_decimal(w).div(2, w)
    return half_pi.mult(1, prec) if x.zero?
    return BigDecimal(0) if x == 1
    return half_pi.mult(2, prec) if x == -1
    # pi/2 - asin(x) cancels for x near 1: use atan(sqrt(1 - x**2) / x).
    return CALC.plus(half_pi, CALC.asin(-x, w)).mult(1, prec) if x.negative?

    sine = CALC.sqrt(CALC.minus(CALC.one, CALC.times(x, x)), w + 2)
    CALC.atan(sine.div(x, w + 2), w).mult(1, prec)
  end

  def atan(x, prec)
    prec = CALC.precision(prec, :atan)
    x = CALC.coerce(x, prec, :atan)
    return CALC.nan_result if x.nan?

    w = prec + CALC::GUARD
    return CALC.pi_decimal(w).div(2 * x.infinite?, prec) if x.infinite?

    CALC.signed_atan(x, w).mult(1, prec)
  end

  def atan2(y, x, prec)
    prec = CALC.precision(prec, :atan2)
    x = CALC.coerce(x, prec, :atan2)
    y = CALC.coerce(y, prec, :atan2)
    return CALC.nan_result if x.nan? || y.nan?

    if x.infinite? || y.infinite?
      one = BigDecimal(1)
      zero = BigDecimal(0)
      x = if x.infinite?
            x.positive? ? one : -one
          else
            zero
          end
      y = if y.infinite?
            y.positive? ? one : -one
          else
            y.sign * zero
          end
    end
    return x.sign >= 0 ? BigDecimal(0) : y.sign * PI(prec) if y.zero?

    w = prec + CALC::GUARD
    negative = y.negative?
    y = -y if negative
    pi = CALC.pi_decimal(w)
    half_pi = pi.div(2, w)
    value = if x.zero?
              half_pi
            elsif x.positive?
              y < x ? CALC.atan(y.div(x, w), w) : CALC.minus(half_pi, CALC.atan(x.div(y, w), w))
            elsif y < -x
              CALC.minus(pi, CALC.atan(y.div(-x, w), w))
            else
              CALC.plus(half_pi, CALC.atan((-x).div(y, w), w))
            end
    (negative ? -value : value).mult(1, prec)
  end

  def sinh(x, prec)
    prec = CALC.precision(prec, :sinh)
    x = CALC.coerce(x, prec, :sinh)
    return CALC.nan_result if x.nan?
    return CALC.infinity_result * x.infinite? if x.infinite?
    return BigDecimal(0) if x.zero?

    w = prec + CALC::GUARD
    return CALC.sinh_small(x, w).mult(1, prec) if x.abs < 1

    if x.exponent >= 21
      e = exp(x, prec + 16)
      return (e - BigDecimal(1).div(e, prec + 16)).div(2, prec)
    end
    e = CALC.exp(x, w)
    e.sub(CALC.one.div(e, w), w).div(2, prec)
  end

  def cosh(x, prec)
    prec = CALC.precision(prec, :cosh)
    x = CALC.coerce(x, prec, :cosh)
    return CALC.nan_result if x.nan?
    return CALC.infinity_result if x.infinite?
    return BigDecimal(1) if x.zero?

    w = prec + CALC::GUARD
    return CALC.cosh_small(x, w).mult(1, prec) if x.abs < 1

    if x.exponent >= 21
      e = exp(x, prec + 16)
      return (e + BigDecimal(1).div(e, prec + 16)).div(2, prec)
    end
    e = CALC.exp(x, w)
    e.add(CALC.one.div(e, w), w).div(2, prec)
  end

  def tanh(x, prec)
    prec = CALC.precision(prec, :tanh)
    x = CALC.coerce(x, prec, :tanh)
    return CALC.nan_result if x.nan?
    return BigDecimal(x.infinite?) if x.infinite?
    return BigDecimal(0) if x.zero?

    w = prec + CALC::GUARD
    return CALC.sinh_small(x, w).div(CALC.cosh_small(x, w), prec) if x.abs < 1

    if x.exponent >= 21
      e = exp(x, prec + 16)
      inverse = BigDecimal(1).div(e, prec + 16)
      return (e - inverse).div(e + inverse, prec)
    end
    # tanh |x| = (1 - t) / (1 + t) with t = e**(-2|x|).
    t = CALC.exp(CALC.times(x.abs, BigDecimal(-2)), w)
    value = CALC.one.sub(t, w).div(CALC.one.add(t, w), w)
    (x.negative? ? -value : value).mult(1, prec)
  end

  def asinh(x, prec)
    prec = CALC.precision(prec, :asinh)
    x = CALC.coerce(x, prec, :asinh)
    return CALC.nan_result if x.nan?
    return CALC.infinity_result * x.infinite? if x.infinite?
    return -asinh(-x, prec) if x.negative?
    return BigDecimal(0) if x.zero?

    w = prec + CALC::GUARD
    root = CALC.sqrt(CALC.plus(CALC.times(x, x), CALC.one), w + [-x.exponent, 0].max)
    CALC.log(CALC.plus(x, root), w).mult(1, prec)
  end

  def acosh(x, prec)
    prec = CALC.precision(prec, :acosh)
    x = CALC.coerce(x, prec, :acosh)
    raise Math::DomainError, 'Out of domain argument for acosh' if x < 1
    return CALC.infinity_result if x.infinite?
    return CALC.nan_result if x.nan?
    return BigDecimal(0) if x == 1

    w = prec + CALC::GUARD
    root = CALC.sqrt(CALC.minus(CALC.times(x, x), CALC.one), w)
    CALC.log(CALC.plus(x, root), w).mult(1, prec)
  end

  def atanh(x, prec)
    prec = CALC.precision(prec, :atanh)
    x = CALC.coerce(x, prec, :atanh)
    raise Math::DomainError, 'Out of domain argument for atanh' if x < -1 || x > 1
    return CALC.nan_result if x.nan?
    return CALC.infinity_result if x == 1
    return -CALC.infinity_result if x == -1
    return BigDecimal(0) if x.zero?

    w = prec + CALC::GUARD
    up = CALC.log(CALC.plus(CALC.one, x), w)
    down = CALC.log(CALC.minus(CALC.one, x), w)
    CALC.minus(up, down).div(2, prec)
  end

  def log2(x, prec) = CALC.log_base(x, prec, 2, :log2)
  def log10(x, prec) = CALC.log_base(x, prec, 10, :log10)

  def log1p(x, prec)
    prec = CALC.precision(prec, :log1p)
    x = CALC.coerce(x, prec, :log1p)
    raise Math::DomainError, 'Out of domain argument for log1p' if x < -1

    log(x + 1, prec)
  end

  def expm1(x, prec)
    prec = CALC.precision(prec, :expm1)
    x = CALC.coerce(x, prec, :expm1)
    return BigDecimal(-1) if x.infinite? == -1

    exp_prec = if x < -1
                 prec + (0.4342944819032518 * x).ceil + 16
               elsif x < 1
                 prec - x.exponent + 16
               else
                 prec
               end
    return BigDecimal(-1) if exp_prec <= 0

    exp(x, exp_prec).sub(1, prec)
  end

  def erf(x, prec)
    prec = CALC.precision(prec, :erf)
    x = CALC.coerce(x, prec, :erf)
    return CALC.nan_result if x.nan?
    return BigDecimal(x.infinite?) if x.infinite?
    return BigDecimal(0) if x.zero?
    return -erf(-x, prec) if x.negative?
    return BigDecimal(1) if x > 5_000_000_000

    w = prec + CALC::GUARD
    value = CALC.erf(x, w)
    value ? value.mult(1, prec) : BigDecimal(1).sub(CALC.tiny(w), prec)
  end

  def erfc(x, prec)
    prec = CALC.precision(prec, :erfc)
    x = CALC.coerce(x, prec, :erfc)
    return CALC.nan_result if x.nan?
    return BigDecimal(1 - x.infinite?) if x.infinite?
    return BigDecimal(1) if x.zero?

    w = prec + CALC::GUARD
    if x.negative?
      value = CALC.erf(-x, w)
      return value ? CALC.plus(CALC.one, value).mult(1, prec) : BigDecimal(2).sub(CALC.tiny(w), prec)
    end
    return CALC.underflow_result if x > 5_000_000_000

    CALC.erfc(x, w).mult(1, prec)
  end

  def gamma(x, prec)
    prec = CALC.precision(prec, :gamma)
    x = CALC.coerce(x, prec, :gamma)
    CALC.gamma_finite!(x)
    w = prec + CALC::GUARD
    if x < 0.5
      raise Math::DomainError, 'Numerical argument is out of domain - gamma' if x.frac.zero?

      # Euler's reflection formula: gamma(x) gamma(1 - x) = pi / sin(pi x).
      sine = CALC.sin_pi(x, w)
      rest = CALC.gamma_positive(CALC.minus(CALC.one, x), w)
      return CALC.pi_decimal(w).div(sine.mult(rest, w), prec)
    end
    x = x.mult(1, prec + 16 + x.exponent + 10)
    CALC.gamma_positive(x, w).mult(1, prec)
  end

  def lgamma(x, prec)
    prec = CALC.precision(prec, :lgamma)
    x = CALC.coerce(x, prec, :lgamma)
    CALC.gamma_finite!(x)
    w = prec + CALC::GUARD
    if x < 0.5
      return [BigDecimal::INFINITY, 1] if x.frac.zero?

      value, sign = CALC.lgamma_reflected(x, w)
      return [value.mult(1, prec), sign]
    end
    prec2 = prec + 16
    near_one = x < 3 ? (x - 1).exponent : 0
    near_two = x < 3 ? (x - 2).exponent : 0
    if near_one < -prec2 || near_two < -prec2
      # So close to 1 or 2 that ln gamma is linear there, as in bigdecimal 4.x.
      base = near_one < -prec2 ? 1 : 2
      d = BigDecimal(1)._decimal_shift(1 - prec2)
      value, sign = lgamma(base + d, prec2)
      return [value.mult(x - base, prec2).div(d, prec), sign]
    end
    extra = [-near_one, -near_two, 0].max
    x = x.mult(1, prec2 + extra + x.exponent + 10)
    if x.frac.zero? && x <= CALC::FACTORIAL_LIMIT
      factorial = CALC.factorial(x.to_i - 1)
      return [BigDecimal(0), 1] if factorial == 1

      return [CALC.log(BigDecimal(factorial), w).mult(1, prec), 1]
    end
    digits = w + extra
    loop do
      value = CALC.lgamma_positive(x, digits)
      return [value.mult(1, prec), 1] if value.nonzero? && digits + value.exponent >= w

      digits += w - (digits + (value.zero? ? -digits : value.exponent)) + 5
    end
  end

  def frexp(x)
    x = CALC.coerce(x, 0, :frexp)
    return [x, 0] unless x.finite?

    exponent = x.exponent
    [x._decimal_shift(-exponent), exponent]
  end

  def ldexp(x, exponent)
    x = CALC.coerce(x, 0, :ldexp)
    x.finite? ? x._decimal_shift(exponent) : x
  end

  def PI(prec) # rubocop:disable Naming/MethodName
    prec = CALC.precision(prec, :PI)
    CALC.pi_decimal(prec + 10).mult(1, prec)
  end

  def E(prec) # rubocop:disable Naming/MethodName
    prec = CALC.precision(prec, :E)
    exp(1, prec)
  end
end
