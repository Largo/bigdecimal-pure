# frozen_string_literal: true

# `require 'bigdecimal'`: the native bigdecimal when it is installed, else the
# pure Ruby one from this gem.
require_relative 'bigdecimal_pure'

require_relative 'bigdecimal/pure' unless defined?(BigDecimal) || BigDecimalPure.require_native('bigdecimal')
