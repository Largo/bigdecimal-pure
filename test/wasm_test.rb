# frozen_string_literal: true

# The place this gem is for: runs every case of test/support/cases.rb with
# the pure class inside ruby.wasm (CRuby compiled to WebAssembly, under node)
# and fails on any result that differs from the pure class in this Ruby,
# which test/compare_test.rb holds against the native one. Needs node and the
# npm package @ruby/4.0-wasm-wasi:
#   RUBY_WASM_DIST=node_modules/@ruby/4.0-wasm-wasi/dist ruby test/wasm_test.rb
require 'fileutils'
require 'rbconfig'
require_relative 'support/cases'

root = File.expand_path('..', __dir__)
dist = ENV.fetch('RUBY_WASM_DIST') { abort 'set RUBY_WASM_DIST to the dist directory of @ruby/4.0-wasm-wasi' }
work = File.join(root, 'tmp', 'wasm')
FileUtils.mkdir_p(work)

# ruby.wasm has no require for files of ours: inline the lib in load order.
lib = %w[bigdecimal_pure/version.rb bigdecimal_pure.rb bigdecimal_pure/decimal.rb bigdecimal_pure/calc.rb
         bigdecimal_pure/math.rb bigdecimal_pure/util.rb].map do |file|
  File.read(File.join(root, 'lib', file)).gsub(/^\s*require_relative .*$/, '')
end
cases = Cases.all
program = File.join(work, 'program.rb')
File.write(program,
           [*lib, "CASES = #{cases.inspect}.freeze",
            File.read(File.join(__dir__, 'support', 'wasm_loop.rb'))].join("\n"))

output = File.join(work, 'output.txt')
system('node', File.join(__dir__, 'support', 'wasm_run.mjs'), dist, program, output, exception: true)

def results(text)
  text.gsub("\r\n", "\n").split(/^(?=\d+\t)/).drop_while { |part| !part.match?(/\A\d+\t/) }.to_h do |part|
    index, value = part.chomp.split("\t", 2)
    [index, value]
  end
end

header, = File.read(output).lines
wasm = results(File.read(output))
here = results(IO.popen({ 'BIGDECIMAL_PURE' => '1' }, [RbConfig.ruby, File.join(__dir__, 'support', 'run_cases.rb')],
                        &:read))
unless wasm.size == cases.size && here.size == cases.size
  abort "expected #{cases.size} results, got #{wasm.size} from ruby.wasm and #{here.size} here"
end

# Threads do not exist in ruby.wasm.
differences = cases.each_index.reject { |i| cases[i].include?('Thread.') || wasm[i.to_s] == here[i.to_s] }
differences.first(40).each do |i|
  puts "  FAIL #{cases[i]}"
  puts "       ruby.wasm: #{wasm[i.to_s]}"
  puts "       here:      #{here[i.to_s]}"
end
abort "#{differences.size} of #{cases.size} cases differ in ruby.wasm" unless differences.empty?
puts "All #{cases.size} cases give the same results in #{header.strip}."
