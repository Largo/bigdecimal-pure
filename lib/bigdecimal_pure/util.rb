# frozen_string_literal: true

# bigdecimal/util of bigdecimal 4.x: to_d on the numbers, strings and nil.

class Integer
  def to_d = BigDecimal(self)
end

class Float
  def to_d(precision = 0) = BigDecimal(self, precision)
end

class String
  def to_d = BigDecimal.interpret_loosely(self)
end

class BigDecimal
  # Plain notation as bigdecimal/util writes it, which drops the sign of a
  # value between -1 and 0.
  def to_digits
    return to_s if nan? || infinite? || zero?

    whole = to_i.to_s
    _, digits, _, exponent = frac.split
    "#{whole}.#{'0' * -exponent}#{digits}"
  end

  def to_d = self
end

class Rational
  def to_d(precision = 0) = BigDecimal(self, precision)
end

class Complex
  def to_d(precision = 0)
    BigDecimal(self) unless imaginary.zero? # raises the error for a non-zero imaginary part
    BigDecimal(real, precision)
  end
end

class NilClass
  def to_d = BigDecimal(0)
end
