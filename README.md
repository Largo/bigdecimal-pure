# bigdecimal-pure

BigDecimal in pure Ruby, for places where the C extension cannot run —
ruby.wasm above all. Where the native `bigdecimal` gem is installed, it wins
automatically.

```ruby
gem 'bigdecimal-pure'
```

```ruby
require 'bigdecimal'        # native if available, pure Ruby otherwise
require 'bigdecimal/util'   # to_d, either way
require 'bigdecimal/math'   # BigMath, either way

BigDecimal('0.1') + BigDecimal('0.2')  # => 0.3e0
BigMath.PI(50)                          # => 0.31415926535897932384626433832795028841971693993751e1
BigDecimalPure.pure?                    # which one you got
```

`require 'bigdecimal/pure'` loads the pure class unconditionally (unless a
BigDecimal is already defined). `BIGDECIMAL_PURE=1` makes `require 'bigdecimal'`
skip the native one.

## How the native one is found

`require 'bigdecimal'` activates the `bigdecimal` gem if it is installed (under
Bundler: if it is in the bundle), then loads the first `bigdecimal.rb` on the
load path that is not this gem's; on old Rubies it falls back to
`bigdecimal.so`. Only when all of that fails does the pure class load.

## What the pure class does

What bigdecimal 4.x does, with the same results:

- decimal strings exactly (`"0.1" + "0.2"` is `0.3`), with the same grammar
  as the C version, `BigDecimal.interpret_loosely` and `String#to_d`;
- NaN, `Infinity`, `-Infinity` and `-0`: `1 / 0` is `Infinity`, `0 / 0` is
  `NaN`, and `BigDecimal.mode` turns each of them into an exception;
- `BigDecimal.mode(BigDecimal::ROUND_MODE, ...)` and `BigDecimal.limit`, per
  thread, with `save_exception_mode`, `save_rounding_mode` and `save_limit`;
- the precision of each result: `+ - *` are exact unless a limit or a
  precision argument says otherwise, `/` keeps the larger operand's precision
  plus 16 digits (at least 32), a Rational operand is converted to as many
  digits as the C version uses, `add/sub/mult/div(x, digits)` round to that;
- `round/floor/ceil/truncate` with digits, every `ROUND_*` mode and `half:`;
  `%`, `divmod`, `remainder`; `**` and `power`, exact for Integer powers;
  `sqrt(digits)`, exact when the root is;
- `to_s` in every format (`'F'`, `'E'`, digit groups, `'+'`, `' '`),
  `precision`, `scale`, `n_significant_digits`, `exponent`, `split`,
  `_dump`/`_load` for `Marshal`, comparisons and coercion with Integer, Float,
  Rational and Complex;
- `BigDecimal(float, digits)` digit for digit as the C version, which rounds
  with the dtoa of Ruby and inherits its one-half shortcut;
- `BigMath` to any precision: `exp`, `log`, `log2`, `log10`, `log1p`, `expm1`,
  `sqrt`, `cbrt`, `hypot`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`,
  `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `erf`, `erfc`, `gamma`,
  `lgamma`, `frexp`, `ldexp`, `PI` and `E`.

The C version keeps its digits in 9-digit words, and a few results show it:
the precision of a Rational operand, the prefix of `_dump`, `ROUND_UP` to a
position far left of the number, and division, which rounds from the words
it has computed. The pure class counts those words too.

### Where the two can differ

- `BigMath` computes each result with 24 more digits and rounds once; the C
  version rounds after every step and carries 16. When the exact value lies
  closer than about 10**-(prec + 16) to a number of `prec` digits — in a
  rounding mode other than the half modes, or for an argument so small that
  the result is nearly the argument or nearly 1 — the last digit can differ
  by one. Where that happened in the tests, the pure result was the correct
  one: `BigMath.cos(0, 10)` in `ROUND_DOWN` is `1`, the C version says
  `0.9999999999`.
- `hash` values differ, and the C version's debugging methods (`vpdivd`,
  `vpmult`, ...) and its internal `BigDecimal::Internal` are not there.
- It is Ruby: basic operations take a few microseconds instead of a fraction
  of one. BigMath works on Integers and keeps up with the C version's, which
  is Ruby too: faster at 50 digits, about even at 500 (gamma a little
  slower).

## Thanks

This gem only stands in where the real one cannot run. The real one is
[ruby/bigdecimal](https://github.com/ruby/bigdecimal), and its behaviour is
what this gem copies. Thank you to its authors and maintainers: Shigeo
Kobayashi, who wrote it, Kenta Murata, Zachary Scott, tompng, and everyone
who has contributed to it.

## Tests

```
bundle exec rake
```

runs the pure class against known values, checks that the native one loads
when it is there, and runs about 8,500 expressions with both and compares
every result, error class and message (`test/compare_test.rb`; more with
`CASES_SEED=7 CASES_SCALE=5`). `bundle exec rake wasm` runs the same
expressions in ruby.wasm under node, with `RUBY_WASM_DIST` pointing to the
`dist` directory of the npm package `@ruby/4.0-wasm-wasi`.

## License

MIT
