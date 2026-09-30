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

BigDecimal('0.1') + BigDecimal('0.2')  # => 0.3e0
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

Built on `Rational`, so it is exact where BigDecimal is exact:

- decimal strings (`"0.1" + "0.2"` is `0.3`), `+ - *`, rounding;
- division and `sqrt` to 20 significant digits by default, like the original;
- `round/floor/ceil/truncate` with digits and all `ROUND_*` modes;
- `to_s` as `0.123e1`, `to_s('F')` as `1.23`; comparisons with Integer, Float
  and Rational; `to_d` from `bigdecimal/util`; `Marshal`.

Not supported: NaN and Infinity (they raise), `BigDecimal.limit` and `.mode`,
precision bookkeeping. `BigMath` goes through Float, so it is good to about 15
digits whatever precision is asked for.

Unlike [hanami-wasm's shim](https://github.com/katafrakt/hanami-wasm)
(`BigDecimal(v) = v.to_i`), the value is kept: `BigDecimal("0.1")` is not 0.

## Tests

```
bundle exec rake
```

## License

MIT
