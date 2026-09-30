# frozen_string_literal: true

require_relative 'lib/bigdecimal_pure/version'

Gem::Specification.new do |spec|
  spec.name     = 'bigdecimal-pure'
  spec.version  = BigDecimalPure::VERSION
  spec.authors  = ['Andi']
  spec.email    = ['andi@idogawa.com']

  spec.summary  = 'BigDecimal in pure Ruby, used only where the native one is missing.'
  spec.description = "`require 'bigdecimal'` loads the native bigdecimal when it is installed " \
                     'and otherwise a pure Ruby BigDecimal that behaves like bigdecimal 4.x, ' \
                     'NaN, modes, limit and BigMath to any precision included, for ruby.wasm ' \
                     'and other places without a C compiler.'
  spec.homepage = 'https://github.com/Largo/bigdecimal-pure'
  spec.license  = 'MIT'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'LICENSE', 'README.md', 'CHANGELOG.md']
  spec.require_paths = ['lib']
end
