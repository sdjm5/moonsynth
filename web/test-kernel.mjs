// End-to-end test of the moonsynth wasm kernel: drives the same exports the
// AudioWorklet drives, over linear memory, and asserts audio physics.
// Run after `moon build --target wasm`:
//   cp _build/wasm/debug/build/src/kernel/kernel.wasm web/synth.wasm
//   node web/test-kernel.mjs
import { readFileSync } from 'node:fs';

const OUT_ADDR = 64 * 1024 * 1024;
let passed = 0;
const check = (name, ok) => {
  if (ok) passed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`);
};
const rms = (f, from, to) => {
  let s = 0;
  for (let i = from; i < to; i++) s += f[i] * f[i];
  return Math.sqrt(s / (to - from));
};

const bytes = readFileSync(new URL('./synth.wasm', import.meta.url));
const mod = await WebAssembly.instantiate(bytes, {});
const E = mod.instance.exports;

check('exports present', ['moon_init', 'note_on', 'note_off', 'set_param', 'panic', 'voice_count', 'render', 'memory']
  .every((n) => E[n] !== undefined));

E.moon_init(44100);
const buf = new Float32Array(E.memory.buffer, OUT_ADDR, 8192);

// silence before any note
E.render(OUT_ADDR, 4096);
check('silent before note_on', rms(buf, 0, 8192) < 0.0001);

// a note sounds
E.set_param(6, 8000); // cutoff
E.set_param(14, 0);   // dry
E.note_on(60, 108);
E.render(OUT_ADDR, 4096);
check('note 60 sounds (rms > 0.01)', rms(buf, 1024, 4096) > 0.01);
check('one voice active', E.voice_count() === 1);

// frequency: C4 through zero crossings on a clean sine patch
E.panic();          // kill the releasing voice so only the sine sounds
E.set_param(0, 0);  // osc1 sine
E.set_param(4, 0);  // osc2 out
E.note_on(60, 108);
E.render(OUT_ADDR, 4096); // settle
E.render(OUT_ADDR, 4096);
// scan the LEFT channel only — the buffer is interleaved stereo
let zc = 0;
for (let i = 1; i < 2048; i++) if (buf[(i - 1) * 2] <= 0 && buf[i * 2] > 0) zc++;
const hz = (zc / 2048) * 44100;
check(`C4 frequency (${hz.toFixed(1)} Hz within 250–275)`, hz > 250 && hz < 275);

// polyphony cap and voice stealing
for (let i = 0; i < 20; i++) E.note_on(40 + i, 100);
check('polyphony capped at 8', E.voice_count() === 8);

// panic silences instantly
E.panic();
E.render(OUT_ADDR, 128);
let peak = 0;
for (let i = 0; i < 256; i++) peak = Math.max(peak, Math.abs(buf[i]));
check('silent after panic', peak === 0);

// release tail: fast-release pluck goes silent
E.set_param(8, 0.002);
E.set_param(9, 0.2);
E.set_param(10, 0);
E.set_param(11, 0.05);
E.note_on(72, 120);
E.note_off(72);
for (let k = 0; k < 6; k++) E.render(OUT_ADDR, 4096);
E.render(OUT_ADDR, 4096);
check('release tail silent (rms < 0.0005)', rms(buf, 0, 4096) < 0.0005);
check('voices drained', E.voice_count() === 0);

// throughput: 8 voices, 10 s of stereo
for (let k = 0; k < 8; k++) E.note_on(50 + k * 4, 100);
const frames = 441000;
const t0 = performance.now();
for (let done = 0; done < frames; done += 4096) E.render(OUT_ADDR, 4096);
const t1 = performance.now();
console.log(`     render 10 s stereo @8 voices: ${(t1 - t0).toFixed(1)} ms (realtime factor ${((t1 - t0) / 10000).toFixed(4)})`);
check('renders faster than real time (< 10000 ms)', t1 - t0 < 10000);

console.log(`\n${passed}/10 checks passed`);
process.exit(passed === 10 ? 0 : 1);
