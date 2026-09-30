// Evaluates a Ruby program in ruby.wasm under node and writes the String it
// returns to a file. Used by test/wasm_test.rb:
//   node wasm_run.mjs <dist of @ruby/4.0-wasm-wasi> <program.rb> <output>
// The package's browser build brings its own WASI shim, so plain node runs it.
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';

const [dist, programPath, outputPath] = process.argv.slice(2).map((path) => resolve(path));
const require = createRequire(import.meta.url);
const { DefaultRubyVM } = require(`${dist}/browser.umd.js`);
const module = await WebAssembly.compile(await readFile(`${dist}/ruby+stdlib.wasm`));
const { vm } = await DefaultRubyVM(module, { consolePrint: true });
const result = vm.eval(await readFile(programPath, 'utf8')).toString();
await writeFile(outputPath, result);
