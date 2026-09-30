# frozen_string_literal: true

# `require 'bigdecimal/math'`: the native file with the native bigdecimal. The
# pure class defines everything of bigdecimal/math itself.
require_relative '../bigdecimal'

BigDecimalPure.require_native('bigdecimal/math') unless BigDecimalPure.pure?
