# frozen_string_literal: true

# BigDecimal in pure Ruby. lib/bigdecimal.rb loads this only when no native
# bigdecimal can be found (ruby.wasm, sandboxes without a compiler). Require
# it directly to get the pure version regardless.
#
# It behaves like bigdecimal 4.x: NaN, the infinities and -0, BigDecimal.mode
# and BigDecimal.limit, the precision rules of each operation, and BigMath to
# any precision. bigdecimal/util and bigdecimal/math come with it.

require_relative '../bigdecimal_pure/version'

return if defined?(BigDecimal)

require_relative '../bigdecimal_pure/decimal'
require_relative '../bigdecimal_pure/math'
require_relative '../bigdecimal_pure/util'
