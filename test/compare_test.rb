# frozen_string_literal: true

# Runs every case of test/support/cases.rb with the native bigdecimal and
# with the pure one, each in its own process, and fails on any difference in
# result, error class or message. Needs the bigdecimal gem: ruby test/compare_test.rb
#
# A case written "~prec:expression" may differ by one unit in the prec-th
# digit (see cases.rb for which ones and why).
require 'rbconfig'
require_relative 'support/cases'

runner = File.join(__dir__, 'support', 'run_cases.rb')
run = lambda do |env|
  output = IO.popen(env, [RbConfig.ruby, runner], &:read)
  abort "run_cases.rb failed (#{env.inspect})" unless $?.success? # rubocop:disable Style/SpecialGlobalVars
  output.lines(chomp: true).to_h { |line| line.split("\t", 2) }
end

# "0.123e4" or "-0.5e-3" as a Rational, nil for anything else.
def decimal_value(text)
  match = /\A(-?)0\.(\d+)e(-?\d+)\z/.match(text)
  return nil unless match

  value = Rational(match[2].to_i) * (Rational(10)**(match[3].to_i - match[2].length))
  match[1] == '-' ? -value : value
end

def within_one_unit?(a, b, prec)
  x = decimal_value(a)
  y = decimal_value(b)
  return false unless x && y

  exponent = [a, b].map { |text| text[/e(-?\d+)\z/, 1].to_i }.max
  (x - y).abs <= Rational(10)**(exponent - prec)
end

native = run.call({ 'BIGDECIMAL_PURE' => '0' })
pure = run.call({ 'BIGDECIMAL_PURE' => '1' })
cases = Cases.all
unless native.size == cases.size && pure.size == cases.size
  abort "expected #{cases.size} results, got #{native.size} native and #{pure.size} pure"
end

loose = 0
differences = cases.each_index.reject do |i|
  a = native[i.to_s]
  b = pure[i.to_s]
  next true if a == b

  prec = cases[i][/\A~(\d+):/, 1]
  loose += 1 if prec && within_one_unit?(a, b, prec.to_i)
  prec && within_one_unit?(a, b, prec.to_i)
end
differences.first(60).each do |i|
  puts "  FAIL #{cases[i]}"
  puts "       native: #{native[i.to_s]}"
  puts "       pure:   #{pure[i.to_s]}"
end
abort "#{differences.size} of #{cases.size} cases differ from the native bigdecimal" unless differences.empty?
puts "All #{cases.size} cases match the native bigdecimal (#{loose} of them within one unit in the last digit)."
