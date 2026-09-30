# Changelog

## [0.2.0] - 2026-09-30

The pure class now does what bigdecimal 4.x does, where 0.1.0 did not:

- NaN, `Infinity`, `-Infinity` and `-0`, with `BigDecimal::NAN` and
  `BigDecimal::INFINITY`. `1 / 0` is `Infinity` and `0 / 0` is `NaN`, as in
  the C version; 0.1.0 raised `ZeroDivisionError`.
- `BigDecimal.mode` for the exception modes and the rounding mode, and
  `BigDecimal.limit`, per thread, with the `save_*` blocks.
- The precision of each result as in C: `/` keeps the larger operand's
  precision plus 16 digits, at least 32 (0.1.0 used 20); Rational operands;
  `add/sub/mult/div` with a precision; `sqrt(0)`; `power`.
- `BigMath` to any precision; 0.1.0 went through Float and was good to about
  15 digits. Also the functions bigdecimal 4.x added: `cbrt`, `hypot`, `tan`,
  `asin`, `acos`, `atan2`, `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`,
  `log2`, `log10`, `log1p`, `expm1`, `erf`, `erfc`, `gamma`, `lgamma`,
  `frexp`, `ldexp`.
- `BigDecimal(float, digits)`, division and `ROUND_UP` round exactly as the C
  version does, down to its 9-digit words.
- `BigDecimal.interpret_loosely`, every `to_s` format, `precision_scale`,
  `n_significant_digits`, `split`, `_decimal_shift`.
- As in 4.x, `sqrt` needs its precision and `precs` is gone.

`test/compare_test.rb` runs about 8,500 expressions with the native and the
pure class and compares every result; `test/wasm_test.rb` runs them in
ruby.wasm.

## [0.1.0] - 2026-09-30

- First release: BigDecimal in pure Ruby on Rational, taken from the ruby.wasm
  sandbox of Ren. `require 'bigdecimal'` prefers the native gem when installed.

[0.2.0]: https://github.com/Largo/bigdecimal-pure/releases/tag/v0.2.0
[0.1.0]: https://github.com/Largo/bigdecimal-pure/releases/tag/v0.1.0
