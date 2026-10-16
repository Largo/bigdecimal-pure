# frozen_string_literal: true

require_relative 'bigdecimal_pure/version'

# Finds the native bigdecimal, if there is one, so that `require 'bigdecimal'`
# gets it and this gem's pure Ruby class only fills in where it is missing.
module BigDecimalPure
  OWN_LIB = File.expand_path(__dir__)

  module_function

  # true once the pure class is the BigDecimal in use.
  def pure? = defined?(::BigDecimal::PURE) ? true : false

  # true when the native extension is the BigDecimal in use.
  def native? = defined?(::BigDecimal) && !pure? ? true : false

  # Loads the native `feature` ("bigdecimal", "bigdecimal/util", ...), or
  # returns false when there is none or it does not load. BIGDECIMAL_PURE=1
  # forces false.
  #
  # The native gem's Ruby files can be there without its C extension: a
  # Bundler-built ruby.wasm installs the bigdecimal gem when another gem
  # depends on it, but has no bigdecimal.so. Its bigdecimal.rb then raises
  # LoadError on `require 'bigdecimal.so'`, and the pure class has to load.
  def require_native(feature)
    return false if ENV['BIGDECIMAL_PURE'] == '1'

    activate_native_gem
    path = native_path(feature)
    if path
      require_native_file(path, feature)
    elsif feature == 'bigdecimal'
      require_native_extension
    else
      false
    end
  end

  # `require path`, false on LoadError. A BigDecimal that the failed file
  # left half defined is removed, so the pure class can take its place.
  def require_native_file(path, feature)
    had_bigdecimal = defined?(::BigDecimal)
    require path
    true
  rescue LoadError
    Object.send(:remove_const, :BigDecimal) if feature == 'bigdecimal' && !had_bigdecimal && defined?(::BigDecimal)
    false
  end

  # The bigdecimal gem, installed next to this one: put its lib on the load
  # path. Under Bundler this only works if it is in the bundle, which is right.
  def activate_native_gem
    return unless defined?(Gem) && Gem.respond_to?(:try_activate)

    gem 'bigdecimal'
  rescue LoadError, StandardError
    nil
  end

  # "<feature>.rb" anywhere on the load path except in this gem.
  def native_path(feature)
    $LOAD_PATH.each do |dir|
      dir = File.expand_path(dir.to_s)
      next if dir == OWN_LIB

      candidate = File.join(dir, "#{feature}.rb")
      return candidate if File.file?(candidate)
    end
    nil
  end

  # Old Rubies ship only bigdecimal.so, without a Ruby part.
  def require_native_extension
    require 'bigdecimal.so'
    true
  rescue LoadError
    false
  end
end
