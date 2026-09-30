# frozen_string_literal: true

module BigDecimalPure
  # The arithmetic behind BigMath, on Integers in fixed point: a real r is the
  # Integer r * 10**s for a scale s. Each routine takes a BigDecimal and a
  # number of significant digits w and returns a BigDecimal with at least w
  # correct digits; BigMath asks for its precision plus a margin and rounds
  # once, in the current rounding mode. The C version rounds after each step
  # instead, so the two agree except when the exact value lies within about
  # 10**-(prec+20) of a rounding boundary.
  #
  # Series with alternating terms keep the terms' magnitudes, because Integer
  # division rounds a negative quotient down and a term would never reach 0.
  module Calc # :nodoc: all
    module_function

    # Digits computed beyond the precision BigMath returns.
    GUARD = 24

    @constants = {}
    @bernoulli = []

    def pow10(n) = BigDecimal._pow10(n)
    def ndigits(n) = BigDecimal._ndigits(n.abs)

    # x * 10**s, truncated toward zero.
    def fixed(x, s)
      _, sign, coef, exp = x._parts
      e = exp + s
      v = e >= 0 ? coef * pow10(e) : coef / pow10(-e)
      sign.negative? ? -v : v
    end

    # m * 10**-s, exactly.
    def decimal(m, s) = BigDecimal._make(m.negative? ? -1 : 1, m.abs, -s)

    # Exact sums and products of finite values, untouched by BigDecimal.limit.
    def plus(a, b)
      _, sa, ca, ea = a._parts
      _, sb, cb, eb = b._parts
      e = [ea, eb].min
      sum = (sa * ca * pow10(ea - e)) + (sb * cb * pow10(eb - e))
      BigDecimal._make(sum.negative? ? -1 : 1, sum.abs, e)
    end

    def minus(a, b) = plus(a, -b)

    def times(a, b)
      _, sa, ca, ea = a._parts
      _, sb, cb, eb = b._parts
      BigDecimal._make(sa * sb, ca * cb, ea + eb)
    end

    def one = BigDecimal(1)

    # ---- constants, cached at the largest scale asked for so far ----------

    def constant(name, s)
      digits, value = @constants[name]
      if digits.nil? || digits < s
        digits = [s, (digits || 0) + ((digits || 0) / 2)].max
        guard = ndigits(digits) + 4
        value = yield(digits + guard) / pow10(guard)
        @constants[name] = [digits, value]
      end
      value / pow10(digits - s)
    end

    # atan(1/n) * 10**s: 1/n - 1/(3n^3) + 1/(5n^5) - ...
    def atan_inv(n, s)
      n2 = n * n
      term = pow10(s) / n
      sum = term
      k = 1
      until term.zero?
        term /= n2
        k += 2
        sum += (k % 4 == 1 ? 1 : -1) * (term / k)
      end
      sum
    end

    # atanh(1/n) * 10**s: 1/n + 1/(3n^3) + 1/(5n^5) + ...
    def atanh_inv(n, s)
      n2 = n * n
      term = pow10(s) / n
      sum = term
      k = 1
      until term.zero?
        term /= n2
        k += 2
        sum += term / k
      end
      sum
    end

    # Machin's formula.
    def pi(s) = constant(:pi, s) { |d| (16 * atan_inv(5, d)) - (4 * atan_inv(239, d)) }

    # ln 2 = 18 atanh(1/26) - 2 atanh(1/4801) + 8 atanh(1/8749).
    def ln2(s)
      constant(:ln2, s) { |d| (18 * atanh_inv(26, d)) - (2 * atanh_inv(4801, d)) + (8 * atanh_inv(8749, d)) }
    end

    # ln 10 = 3 ln 2 + ln 1.25, and ln 1.25 = 2 atanh(1/9).
    def ln10(s) = constant(:ln10, s) { |d| (3 * ln2(d)) + (2 * atanh_inv(9, d)) }

    def pi_decimal(w) = decimal(pi(w + 2), w + 2)

    # ---- exp and log ------------------------------------------------------

    # e**x for a finite x with |x| < 10**21, to w digits: e**x = 10**k * e**r
    # with r = x - k ln 10 in [0, ln 10).
    def exp(x, w)
      return one if x.zero?
      # For a tiny x, 1 + x + x**2/2 already has w digits, and a fixed-point
      # computation at w digits would round the x away.
      return plus(one, plus(x, times(times(x, x), BigDecimal('0.5')))) if x.exponent < -(w / 2) - 2

      s0 = [x.exponent, 0].max + 10
      k = fixed(x, s0).div(ln10(s0))
      s = w + ndigits(k) + 12
      r = fixed(x, s) - (k * ln10(s))
      BigDecimal._make(1, exp_fixed(r, s), k - s)
    end

    # e**(r / 10**s) * 10**s for |r / 10**s| below a few units: halve the
    # argument j times, sum the Taylor series, square j times.
    def exp_fixed(r, s)
      return pow10(2 * s) / exp_fixed(-r, s) if r.negative?

      halvings = [Integer.sqrt(3 * s), 4].max
      s2 = s + ndigits(s) + (halvings / 3) + 4
      unit = pow10(s2)
      x = (r * pow10(s2 - s)) >> halvings
      sum = unit
      term = unit
      n = 0
      loop do
        n += 1
        term = term * x / (unit * n)
        break if term.zero?

        sum += term
      end
      halvings.times { sum = sum * sum / unit }
      sum / pow10(s2 - s)
    end

    # ln x for a finite x > 0, x != 1, to w digits, by
    # ln t = 2 atanh((t - 1) / (t + 1)) on t near 1.
    def log(x, w)
      return BigDecimal(0) if x == 1

      if x > BigDecimal('0.5') && x < BigDecimal(2)
        # |ln x| can be as small as |x - 1|: scale for that many digits.
        xr = x.to_r
        d = xr - 1
        magnitude = ndigits(d.numerator) - ndigits(d.denominator)
        s = w + ndigits(w) + 10 + [-magnitude, 0].max
        z = (d * pow10(s) / (xr + 1)).round
        return decimal(2 * atanh_fixed(z, s), s)
      end
      # x = m * 10**e with m in [1, 10), m = t * 2**k with t near 1;
      # |ln x| >= ln 2 here, so a fixed scale gives w digits.
      e = x.exponent - 1
      m = x._decimal_shift(-e)
      k = Math.log2(m.to_f).round
      t = m.to_r / (1 << k)
      s = w + ndigits(w) + ndigits(e.abs + k + 1) + 10
      z = ((t - 1) * pow10(s) / (t + 1)).round
      decimal((2 * atanh_fixed(z, s)) + (k * ln2(s)) + (e * ln10(s)), s)
    end

    # atanh(z / 10**s) * 10**s for |z / 10**s| <= 1/3.
    def atanh_fixed(z, s)
      return -atanh_fixed(-z, s) if z.negative?

      unit = pow10(s)
      z2 = z * z / unit
      term = z
      sum = z
      k = 1
      loop do
        term = term * z2 / unit
        break if term.zero?

        k += 2
        sum += term / k
      end
      sum
    end

    # ---- roots, exactly ---------------------------------------------------

    # [root, exponent, exact]: root * 10**exponent is sqrt(x) rounded down
    # to at least w digits, exact when it is the whole square root.
    def sqrt_digits(x, w)
      _, _, coef, exp = x._parts
      shift = [(2 * w) + 2 - ndigits(coef), 0].max
      shift += 1 if (exp - shift).odd?
      n = coef * pow10(shift)
      root = Integer.sqrt(n)
      [root, (exp - shift) / 2, root * root == n]
    end

    def cbrt_digits(x, w)
      _, _, coef, exp = x._parts
      shift = [(3 * w) + 3 - ndigits(coef), 0].max
      shift += 1 until ((exp - shift) % 3).zero?
      n = coef * pow10(shift)
      root = icbrt(n)
      [root, (exp - shift) / 3, root * root * root == n]
    end

    def icbrt(n)
      return n if n < 2

      x = 1 << ((n.bit_length + 2) / 3)
      loop do
        y = ((2 * x) + (n / (x * x))) / 3
        return x if y >= x

        x = y
      end
    end

    def sqrt(x, w)
      root, exp, = sqrt_digits(x, w)
      BigDecimal._make(1, root, exp)
    end

    # ---- trigonometry -----------------------------------------------------

    # [q, r2, s]: x = q * pi/2 + r with r2 = 2r * 10**s, |r| <= pi/4, and r2
    # good to w + 10 digits. The scale grows until the cancellation in
    # x - q pi/2 leaves enough digits.
    def reduce_half_pi(x, w)
      e = [x.exponent, 0].max
      extra = 0
      loop do
        s = w + e + extra + ndigits(w) + 10
        p = pi(s)
        xs = fixed(x, s)
        q = ((4 * xs) + p).div(2 * p)
        r2 = (2 * xs) - (q * p)
        deficit = (w + 10) - (ndigits(r2) - ndigits(q) - 2)
        deficit = w + 10 + s if r2.zero?
        return [q, r2, s] if deficit <= 0

        extra += deficit + 5
      end
    end

    # sin or cos of a finite nonzero x, to w digits.
    def sin_cos(x, w, cosine)
      q, r2, s = reduce_half_pi(x, w)
      n = q % 4
      use_cos = cosine ? n.even? : n.odd?
      negative = cosine ? [1, 2].include?(n) : n >= 2
      value, scale = sin_or_cos(r2, s, w, use_cos)
      decimal(negative ? -value : value, scale)
    end

    # [value, scale]: sin(r) or cos(r) * 10**scale for r2 = 2r * 10**s.
    def sin_or_cos(r2, s, w, use_cos)
      size = ndigits(r2) - s # |r| is about 10**size
      # sin(r) is about r, cos(r) - 1 about r**2/2: keep those digits too.
      t = w + ndigits(w) + 10 + (use_cos ? [-2 * size, 0].max : [-size, 0].max)
      a = r2.abs * pow10(t) / (2 * pow10(s))
      return [cos_fixed(a, t), t] if use_cos

      [r2.negative? ? -sin_fixed(a, t) : sin_fixed(a, t), t]
    end

    def sin_fixed(a, t)
      unit = pow10(t)
      a2 = a * a / unit
      term = a
      sum = a
      k = 1
      loop do
        term = term * a2 / (unit * (k + 1) * (k + 2))
        break if term.zero?

        k += 2
        sum += k % 4 == 1 ? term : -term
      end
      sum
    end

    def cos_fixed(a, t)
      unit = pow10(t)
      a2 = a * a / unit
      term = unit
      sum = unit
      k = 0
      loop do
        term = term * a2 / (unit * (k + 1) * (k + 2))
        break if term.zero?

        k += 2
        sum += k % 4 == 2 ? -term : term
      end
      sum
    end

    # tan of a finite nonzero x, to w digits.
    def tan(x, w)
      q, r2, s = reduce_half_pi(x, w + 5)
      sin_r, sin_scale = sin_or_cos(r2, s, w + 5, false)
      cos_r, cos_scale = sin_or_cos(r2, s, w + 5, true)
      sine = decimal(sin_r, sin_scale)
      cosine = decimal(cos_r, cos_scale)
      # tan(r + q pi/2) is tan r for even q and -cot r for odd q.
      q.even? ? sine.div(cosine, w + 5) : -cosine.div(sine, w + 5)
    end

    # atan of a finite x > 0, to w digits.
    def atan(x, w)
      s = w + ndigits(w) + 10
      if x > one
        # pi/2 - atan(1/x), which is at least pi/4.
        inverse = pow10(2 * s) / fixed(x, s)
        return decimal((pi(s) / 2) - atan_fixed(inverse, s), s)
      end
      s += [-x.exponent, 0].max
      decimal(atan_fixed(fixed(x, s), s), s)
    end

    # atan(a / 10**s) * 10**s for 0 <= a / 10**s <= 1: halve the angle with
    # atan y = 2 atan(y / (1 + sqrt(1 + y**2))) until y < 0.01, then Taylor.
    def atan_fixed(a, s)
      guard = ndigits(s) + 4
      s2 = s + guard
      unit = pow10(s2)
      y = a * pow10(guard)
      halvings = 0
      while y > unit / 100
        y = y * unit / (unit + Integer.sqrt((unit * unit) + (y * y)))
        halvings += 1
      end
      y2 = y * y / unit
      term = y
      sum = y
      k = 1
      loop do
        term = term * y2 / unit
        break if term.zero?

        k += 2
        sum += (k % 4 == 1 ? 1 : -1) * (term / k)
      end
      (sum << halvings) / pow10(guard)
    end

    # ---- hyperbolic functions for |x| < 1, by their series ----------------

    # sinh(x) for finite 0 < |x| < 1, to w digits.
    def sinh_small(x, w)
      t = w + ndigits(w) + 10 + [-x.exponent, 0].max
      a = fixed(x.abs, t)
      unit = pow10(t)
      a2 = a * a / unit
      term = a
      sum = a
      k = 1
      loop do
        term = term * a2 / (unit * (k + 1) * (k + 2))
        break if term.zero?

        k += 2
        sum += term
      end
      decimal(x.negative? ? -sum : sum, t)
    end

    # cosh(x) for finite |x| < 1, to w digits.
    def cosh_small(x, w)
      t = w + ndigits(w) + 10 + [-2 * x.exponent, 0].max
      a = fixed(x.abs, t)
      unit = pow10(t)
      a2 = a * a / unit
      term = unit
      sum = unit
      k = 0
      loop do
        term = term * a2 / (unit * (k + 1) * (k + 2))
        break if term.zero?

        k += 2
        sum += term
      end
      decimal(sum, t)
    end

    # ---- the error function -----------------------------------------------

    # erf(x) * 10**digits for a finite x > 0, with an absolute error of a few
    # units, from the series with only positive terms
    #   erf(x) = 2/sqrt(pi) * exp(-x**2) * sum_n 2**n x**(2n+1) / (1*3*...*(2n+1)).
    def erf_fixed(x, digits)
      grow = ((x.to_f**2) / Math.log(10)).ceil # the sum reaches about 10**grow
      s = digits + grow + ndigits(digits + grow) + 10 + [-x.exponent, 0].max
      unit = pow10(s)
      xs = fixed(x, s)
      x2 = 2 * xs * xs / unit
      term = xs
      sum = xs
      n = 0
      loop do
        n += 1
        term = term * x2 / (unit * ((2 * n) + 1))
        break if term.zero?

        sum += term
      end
      w = digits + ndigits(digits) + 10
      factor = exp(-times(x, x), w).mult(2, w).div(sqrt(pi_decimal(w + 2), w + 2), w)
      fixed(decimal(sum, s).mult(factor, w + grow + 10), digits)
    end

    # erf(x) for a finite x > 0, to w digits, and nil when erf(x) is 1 to
    # more than w digits.
    def erf(x, w)
      return nil if x.to_f**2 > (w + 5) * Math.log(10)

      digits = w + 5 + [-x.exponent, 0].max
      decimal(erf_fixed(x, digits), digits)
    end

    # erfc(x) for a finite x > 0, to w digits.
    def erfc(x, w)
      xf = x.to_f
      if xf < 0.5
        # 1 - erf(x) is about 1 - 1.13 x: keep x's digits as well.
        digits = w + 5 + [-x.exponent, 0].max
        return decimal(pow10(digits) - erf_fixed(x, digits), digits)
      end
      return erfc_asymptotic(x, w) if xf * xf > (w + 12) * Math.log(10)

      # 1 - erf(x) loses about log10(erfc(x)) digits to cancellation.
      lost = ((xf * xf) + Math.log(xf * Math.sqrt(Math::PI))) / Math.log(10)
      digits = w + 10 + lost.ceil
      decimal(pow10(digits) - erf_fixed(x, digits), digits)
    end

    # erfc(x) = exp(-x**2) / (x sqrt(pi)) * sum_n (-1)**n (2n-1)!! / (2x**2)**n
    # for x**2 large enough that the smallest term is below 10**-(w+12).
    def erfc_asymptotic(x, w)
      s = w + ndigits(w) + 12
      unit = pow10(s)
      x2 = fixed(times(times(x, x), BigDecimal(2)), s)
      term = unit
      sum = unit
      n = 0
      loop do
        n += 1
        smaller = term * ((2 * n) - 1) * unit / x2
        break if smaller.zero? || smaller >= term

        term = smaller
        sum += n.odd? ? -term : term
      end
      w2 = w + 10
      root_pi = sqrt(pi_decimal(w2 + 2), w2 + 2)
      exp(-times(x, x), w2).mult(decimal(sum, s), w2).div(x.mult(root_pi, w2), w2)
    end

    # ---- gamma --------------------------------------------------------------

    # B_2, B_4, ..., B_2n as Rationals, from the tangent numbers
    # (Brent and Harvey): B_2k = (-1)**(k-1) * 2k * T_k / (4**k * (4**k - 1)).
    def bernoulli(count)
      return @bernoulli if @bernoulli.size >= count

      n = [count, (@bernoulli.size * 3 / 2) + 8].max
      t = Array.new(n + 1, 0)
      t[1] = 1
      (2..n).each { |k| t[k] = (k - 1) * t[k - 1] }
      (2..n).each do |k| # rubocop:disable Style/CombinableLoops -- the first loop must finish first
        (k..n).each { |j| t[j] = ((j - k) * t[j - 1]) + ((j - k + 2) * t[j]) }
      end
      @bernoulli = (1..n).map do |k|
        four = 1 << (2 * k)
        value = Rational(2 * k * t[k], four * (four - 1))
        k.odd? ? value : -value
      end
    end

    # ln(2 pi) / 2.
    def half_ln_2pi(s)
      constant(:half_ln_2pi, s) do |d|
        fixed(log(times(pi_decimal(d + 5), BigDecimal(2)), d + 5), d) / 2
      end
    end

    # ln Gamma(z) for z >= 2*digits + 10 by Stirling's series, with an
    # absolute error below 10**-digits:
    #   (z - 1/2) ln z - z + ln(2 pi)/2 + sum_k B_2k / (2k (2k-1) z**(2k-1)).
    def lgamma_stirling(z, digits)
      s = digits + ndigits(digits) + 10
      log_z = log(z, s + [z.exponent, 0].max + ndigits(z.exponent.abs + 2) + 5)
      main = fixed(times(minus(z, BigDecimal('0.5')), log_z), s) - fixed(z, s) + half_ln_2pi(s)
      # z**-(2k-1) falls below 10**-s long before B_2k z**-(2k-1) does:
      # carry the powers with as many more digits as the largest B_2k has.
      extra = bernoulli_digits(stirling_terms(z, s)) + 5
      scale = s + extra
      unit = pow10(scale)
      inverse = unit * unit / fixed(z, scale)
      inverse2 = inverse * inverse / unit
      power = inverse
      sum = 0
      k = 0
      loop do
        k += 1
        b = bernoulli(k)[k - 1]
        term = (b.numerator.abs * power) / (b.denominator * 2 * k * ((2 * k) - 1) * pow10(extra))
        break if term.zero?

        sum += b.negative? ? -term : term
        power = power * inverse2 / unit
      end
      decimal(main + sum, s)
    end

    # How many Stirling terms bring |B_2k| / (2k (2k-1) z**(2k-1)) below
    # 10**-s, with |B_2k| about 2 (2k)! / (2 pi)**2k; a few more for safety.
    def stirling_terms(z, s)
      log_z = z.to_f.finite? ? Math.log(z.to_f) : (z.exponent * Math.log(10))
      limit = -(s + 5) * Math.log(10)
      k = 1
      k += 1 while k < 100_000 && log_bernoulli(k) - Math.log(2.0 * k * ((2 * k) - 1)) - (((2 * k) - 1) * log_z) > limit
      k + 10
    end

    # ln |B_2k|, near enough.
    def log_bernoulli(k) = Math.log(2) + Math.lgamma((2 * k) + 1)[0] - (2 * k * Math.log(2 * Math::PI))

    def bernoulli_digits(k) = [(log_bernoulli(k) / Math.log(10)).ceil, 0].max

    # ln Gamma(x) for a finite x >= 0.5, with an absolute error below
    # 10**-digits: Stirling at z = x + m, less ln(x (x+1) ... (x+m-1)).
    def lgamma_positive(x, digits)
      start = (2 * digits) + 10
      m = [start - x.floor, 0].max
      return lgamma_stirling(x, digits) if m.zero?

      z = plus(x, BigDecimal(m))
      stirling = lgamma_stirling(z, digits + 2)
      size = ndigits(((m + 1) * (Math.log([z.to_f, 2].max) + 1)).ceil)
      w = digits + size + ndigits(m) + 10
      product = x
      (1...m).each { |i| product = product.mult(plus(x, BigDecimal(i)), w) }
      s = digits + 5
      decimal(fixed(stirling, s) - fixed(log(product, w), s), s)
    end

    # sin(pi x) for a finite x that is not an integer, to w digits, by
    # reducing x to [-1/2, 1/2] exactly first.
    def sin_pi(x, w)
      n = x.round
      f = minus(x, BigDecimal(n))
      value = sin_cos(times(pi_decimal(w + 10 - [f.exponent, 0].min), f), w + 5, false)
      n.odd? ? -value : value
    end

    def factorial(n)
      return 1 if n < 2

      product_range(2, n)
    end

    def product_range(low, high)
      return low if low == high
      return low * high if high == low + 1

      mid = (low + high) / 2
      product_range(low, mid) * product_range(mid + 1, high)
    end
  end
end
