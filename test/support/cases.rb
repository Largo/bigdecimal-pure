# frozen_string_literal: true

# The expressions test/compare_test.rb evaluates with the native bigdecimal
# and with the pure one: hand-picked edge cases, then generated ones from a
# seed, so both processes build the same list without BigDecimal.
#
# CASES_SEED and CASES_SCALE (default 1) pick other and more generated cases:
#   CASES_SEED=7 CASES_SCALE=5 ruby test/compare_test.rb
module Cases
  ROUNDING = %w[ROUND_UP ROUND_DOWN ROUND_HALF_UP ROUND_HALF_DOWN ROUND_HALF_EVEN ROUND_CEILING ROUND_FLOOR].freeze
  SPECIALS = ['BigDecimal("NaN")', 'BigDecimal("Infinity")', 'BigDecimal("-Infinity")', 'BigDecimal("0")',
              'BigDecimal("-0")'].freeze
  MATH = %w[exp log sqrt cbrt sin cos tan asin acos atan sinh cosh tanh asinh acosh atanh log2 log10 log1p expm1
            erf erfc gamma lgamma].freeze
  PRECISIONS = [1, 2, 5, 10, 16, 20, 32, 50, 100, 200].freeze

  module_function

  def all
    seed = Integer(ENV.fetch('CASES_SEED', '20260930'))
    scale = Integer(ENV.fetch('CASES_SCALE', '1'))
    fixed + generated(Random.new(seed), scale)
  end

  def fixed
    File.readlines(File.join(__dir__, 'fixed_cases.txt'), chomp: true).reject do |line|
      line.strip.empty? || line.start_with?('#')
    end
  end

  def decimal(rng, max_digits = 30)
    digits = Array.new(rng.rand(1..max_digits)) { rng.rand(10) }.join.sub(/\A0+(?=\d)/, '')
    point = rng.rand(0..digits.length)
    text = point == digits.length ? digits : "#{digits[0, point]}.#{digits[point..]}"
    text = "#{text}e#{rng.rand(-40..40)}" if rng.rand < 0.3
    text = "-#{text}" if rng.rand < 0.4
    "BigDecimal(\"#{text}\")"
  end

  def operand(rng)
    case rng.rand(12)
    when 0 then SPECIALS.sample(random: rng)
    when 1 then rng.rand((-10**rng.rand(1..25))..(10**rng.rand(1..25))).to_s
    when 2 then format('%.17g', (rng.rand - 0.5) * (10**rng.rand(-20..20)))
    when 3 then "Rational(#{rng.rand(-1000..1000)}, #{rng.rand(1..999)})"
    else decimal(rng)
    end
  end

  def precision(rng) = [0, 1, 2, 3, 5, 10, 16, 20, 32, 40].sample(random: rng)
  def mode(rng) = "BigDecimal::#{ROUNDING.sample(random: rng)}"

  def with_mode(rng, expression)
    case rng.rand(6)
    when 0 then "BigDecimal.mode(BigDecimal::ROUND_MODE, #{mode(rng)}); #{expression}"
    when 1 then "BigDecimal.limit(#{rng.rand(1..20)}); #{expression}"
    else expression
    end
  end

  def generated(rng, scale)
    cases = []
    (600 * scale).times do
      a = rng.rand < 0.1 ? SPECIALS.sample(random: rng) : decimal(rng)
      b = operand(rng)
      op = %w[+ - * / % <=> == < >=].sample(random: rng)
      cases << with_mode(rng, "#{a} #{op} #{b}")
      cases << with_mode(rng, "#{a}.#{%w[add sub mult div].sample(random: rng)}(#{b}, #{precision(rng)})")
      cases << with_mode(rng, "#{a}.#{%w[divmod remainder div modulo quo].sample(random: rng)}(#{b})")
    end
    (400 * scale).times do
      a = rng.rand < 0.1 ? SPECIALS.sample(random: rng) : decimal(rng)
      n = rng.rand(-8..8)
      cases << "#{a}.round(#{n}, #{mode(rng)})"
      cases << "#{a}.#{%w[floor ceil truncate round].sample(random: rng)}(#{n})"
      cases << "#{a}.#{%w[round floor ceil truncate fix frac to_i to_r to_f abs -@ precision scale n_significant_digits
                          exponent sign split _dump nonzero? to_digits].sample(random: rng)}"
      cases << "#{a}.to_s(#{['"F"', '"E"', '"3F"', '" 4E"', '"+2F"', '5', '"+"', '" "'].sample(random: rng)})"
      cases << with_mode(rng, "#{a}.sqrt(#{precision(rng)})")
      cases << with_mode(rng, "#{a} ** #{rng.rand(-6..12)}")
      cases << with_mode(rng, "#{a}.abs.power(#{rng.rand(-6..12)}, #{precision(rng)})")
    end
    (300 * scale).times do
      text = Array.new(rng.rand(1..8)) do
        ['1', '23', '_', '.', 'e', '-', '+', ' ', '0', 'E5', 'd', '#', 'x'].sample(random: rng)
      end.join
      cases << "BigDecimal(#{text.inspect})"
      cases << "#{text.inspect}.to_d"
      f = (rng.rand - 0.5) * (10**rng.rand(-30..30))
      cases << "BigDecimal(#{format('%.17g', f)}, #{rng.rand(0..17)})"
      cases << "BigDecimal(#{format('%.17g', f)})"
      cases << "BigDecimal(Rational(#{rng.rand((-10**6)..(10**6))}, #{rng.rand(1..(10**6))}), #{rng.rand(0..40)})"
    end
    # Division rounds from the C version's 9-digit words, which only the
    # half and directed modes can tell from exact rounding.
    (300 * scale).times do
      a = decimal(rng, 40)
      b = decimal(rng, 40)
      division = rng.rand < 0.5 ? "#{a} / #{b}" : "#{a}.div(#{b}, #{rng.rand(1..60)})"
      cases << "BigDecimal.mode(BigDecimal::ROUND_MODE, #{mode(rng)}); #{division}"
    end
    MATH.each do |name|
      (60 * scale).times do
        prec = PRECISIONS.sample(random: rng)
        argument = math_argument(rng, name)
        call = "BigMath.#{name}(#{argument}, #{prec})"
        directed = rng.rand < 0.2 && name != 'gamma'
        call = "BigDecimal.mode(BigDecimal::ROUND_MODE, #{mode(rng)}); #{call}" if directed
        # Both work with about prec + 16 digits, so where the exact value lies
        # closer than that to a prec-digit number (a directed rounding mode,
        # or a tiny argument that makes the result nearly x or nearly 1), they
        # may round to neighbours. Such cases need only agree within one unit.
        size = Float(argument[/"([^"]+)"/, 1]).abs
        tiny = size.nonzero? && Math.log10(size) < -(prec + 14) / 2.0
        call = "~#{prec}:#{call}" if directed || tiny
        cases << call
      end
    end
    (40 * scale).times do
      prec = [5, 20, 40, 100].sample(random: rng)
      cases << "BigMath.atan2(#{wide_decimal(rng)}, #{wide_decimal(rng)}, #{prec})"
      cases << "BigMath.hypot(#{wide_decimal(rng)}, #{wide_decimal(rng)}, #{prec})"
      cases << "#{small_decimal(rng)}.abs ** #{small_decimal(rng)}"
      cases << "#{small_decimal(rng)}.abs.power(#{small_decimal(rng)}, #{prec})"
      cases << "BigDecimal(\"#{rng.rand(1..999)}.#{rng.rand(1..999)}\").power(#{rng.rand(20..400)}, #{prec})"
    end
    [1, 2, 10, 50, 100, 500].each do |n|
      cases << "BigMath.PI(#{n})"
      cases << "BigMath.E(#{n})"
    end
    cases
  end

  def math_argument(rng, name)
    case name
    when 'asin', 'acos', 'atanh' then decimal_between(rng, -1, 1)
    when 'acosh' then "BigDecimal(\"#{1 + (rng.rand * (10**rng.rand(-10..3)))}\")"
    when 'gamma', 'lgamma'
      value = (rng.rand - 0.3) * (10**rng.rand(0..3))
      "BigDecimal(\"#{value.round(rng.rand(1..12))}\")"
    when 'erf', 'erfc' then "BigDecimal(\"#{((rng.rand - 0.3) * rng.rand(0.0..12.0)).round(rng.rand(1..15))}\")"
    when 'log', 'log2', 'log10', 'sqrt', 'cbrt' then "#{wide_decimal(rng)}.abs"
    when 'log1p' then "BigDecimal(\"#{(-1 + (rng.rand * (10**rng.rand(-1..3)))).round(rng.rand(1..15))}\")"
    when 'exp', 'expm1', 'sinh', 'cosh', 'tanh'
      rng.rand < 0.3 ? "BigDecimal(\"#{((rng.rand - 0.5) * 2000).round(3)}\")" : small_decimal(rng)
    when 'sin', 'cos', 'tan' then rng.rand < 0.3 ? wide_decimal(rng) : small_decimal(rng)
    else rng.rand < 0.5 ? wide_decimal(rng) : small_decimal(rng)
    end
  end

  def small_decimal(rng)
    value = (rng.rand - 0.5) * 2 * (10**rng.rand(-6..2))
    "BigDecimal(\"#{value.round(rng.rand(1..15))}\")"
  end

  # Anything from 1e-40 to 1e40, with up to 30 digits.
  def wide_decimal(rng)
    digits = Array.new(rng.rand(1..30)) { rng.rand(10) }.join
    "BigDecimal(\"#{'-' if rng.rand < 0.4}0.#{digits}e#{rng.rand(-40..40)}\")"
  end

  def decimal_between(rng, low, high)
    "BigDecimal(\"#{(low + ((high - low) * rng.rand)).round(rng.rand(1..15))}\")"
  end
end
