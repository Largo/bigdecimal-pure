# frozen_string_literal: true

# `require 'bigdecimal/util'`: the native file with the native bigdecimal. The
# pure class defines everything of bigdecimal/util itself.
require_relative '../bigdecimal'

BigDecimalPure.require_native('bigdecimal/util') unless BigDecimalPure.pure?
