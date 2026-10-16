# frozen_string_literal: true

# The native gem's bigdecimal.rb on the load path but its bigdecimal.so
# missing, as in a Bundler-built ruby.wasm: `require 'bigdecimal'` must fall
# back to the pure class, not raise LoadError, and must not keep a BigDecimal
# that the failed file half defined. Gems disabled, outside Bundler, like
# fallback_test.rb:
#   ruby --disable-gems test/broken_native_test.rb
require 'tmpdir'

exts = %w[.rb .so .bundle .dll].map { |ext| "bigdecimal#{ext}" }
$LOAD_PATH.reject! { |dir| exts.any? { |name| File.exist?(File.join(dir, name)) } }

Dir.mktmpdir do |native|
  # Opens the class before its extension fails to load, to check that the
  # half-defined class is gone afterwards.
  File.write(File.join(native, 'bigdecimal.rb'), <<~RUBY)
    class BigDecimal
      HALF_LOADED = true
    end
    require 'bigdecimal.so'
  RUBY
  $LOAD_PATH.unshift native
  $LOAD_PATH.unshift File.expand_path('../lib', __dir__)

  begin
    require 'bigdecimal'
    require 'bigdecimal/util'
  rescue LoadError => e
    abort "require 'bigdecimal' raised #{e.class}: #{e.message}"
  end

  abort 'expected the pure bigdecimal' unless BigDecimalPure.pure?
  abort 'half-loaded native BigDecimal left behind' if defined?(BigDecimal::HALF_LOADED)
  abort 'pure BigDecimal is not a Numeric' unless BigDecimal < Numeric
  abort 'wrong sum' unless (BigDecimal('0.1') + '0.2'.to_d).to_s('F') == '0.3'
end
puts "pure bigdecimal-pure #{BigDecimal::VERSION} loaded past a broken native bigdecimal. ok"
