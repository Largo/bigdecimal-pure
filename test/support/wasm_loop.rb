# frozen_string_literal: true

# The end of the program test/wasm_test.rb runs in ruby.wasm, after the pure
# lib and CASES: evaluate each case, return "index\tresult" lines. As in
# run_cases.rb, but without Timeout, which needs threads.
def show(value)
  case value
  when BigDecimal then value.inspect
  when Array then "[#{value.map { |v| show(v) }.join(', ')}]"
  else "#{value.inspect}:#{value.class}"
  end
end

def evaluate(source)
  BigDecimal.save_exception_mode do
    BigDecimal.save_rounding_mode do
      BigDecimal.save_limit { show(eval(source, TOPLEVEL_BINDING.dup)) } # rubocop:disable Security/Eval
    end
  end
rescue StandardError, ScriptError => e
  "!! #{e.class}: #{e.message}"
end

lines = CASES.each_with_index.map { |source, i| "#{i}\t#{evaluate(source.sub(/\A~\d+:/, ''))}" }
"#{RUBY_PLATFORM} #{RUBY_VERSION} pure=#{BigDecimalPure.pure?}\n#{lines.join("\n")}"
