// Builds a short demo track out of the library: a pad, an arpeggio over the
// same progression, a driven bass line, and a closing chord with the reverb
// tail left to ring. Everything is the wasm engine — no samples, no DAW.
//
//   node examples/demo.mjs                 → out/demo.wav
//   node examples/demo.mjs docs/demo-music.wav
//
// It prints each section's measured level as it goes, so the file is checked
// as it is written rather than assumed to be fine.
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { encodeWav, rms } from './wav.mjs';
import { loadEngine, P, waveId, arpModeId } from './engine.mjs';

const SR = 48000;
const outPath = process.argv[2] ?? 'out/demo.wav';

const E = await loadEngine(SR);
const left = [];
const right = [];

// A minor – F – C – G, the oldest progression there is.
const PROGRESSION = [
  { name: 'Am', pad: [57, 60, 64], root: 45 },
  { name: 'F', pad: [53, 57, 60], root: 41 },
  { name: 'C', pad: [60, 64, 67], root: 36 },
  { name: 'G', pad: [55, 59, 62], root: 43 },
];

let sectionStart = 0;
function logSection(name) {
  const l = left.slice(sectionStart);
  const r = right.slice(sectionStart);
  const level = Math.sqrt((rms(l) ** 2 + rms(r) ** 2) / 2);
  const peak = Math.max(
    l.reduce((m, v) => Math.max(m, Math.abs(v)), 0),
    r.reduce((m, v) => Math.max(m, Math.abs(v)), 0),
  );
  const seconds = (l.length / SR).toFixed(2);
  console.log(
    `  ${name.padEnd(22)} ${seconds.padStart(5)} s   rms ${level.toFixed(4)}   peak ${peak.toFixed(3)}`,
  );
  sectionStart = left.length;
}

console.log('rendering demo track');

// --- 1. pad -----------------------------------------------------------------
// Slow attack, wide reverb, no arpeggiator: the bed the rest sits on.
E.patch({
  osc1_wave: waveId('tri'),
  osc2_wave: waveId('sine'),
  osc2_mix: 0.5,
  osc1_detune: -6,
  osc2_detune: 6,
  filter_type: 0,
  cutoff: 3200,
  resonance: 0.7,
  attack: 0.35,
  decay: 0.4,
  sustain: 1.0,
  release: 0.7,
  delay_mix: 0.15,
  delay_feedback: 0.3,
  delay_time: 0.33,
  reverb_size: 0.9,
  reverb_damp: 0.25,
  reverb_mix: 0.5,
  reverb_width: 1.0,
  drive: 0,
  drive_mix: 0,
  arp_on: 0,
  master: 0.6,
});
for (const step of PROGRESSION) {
  for (const n of step.pad) E.noteOn(n, 90);
  E.renderInto(left, right, 1.0);
  for (const n of step.pad) E.noteOff(n);
  E.renderInto(left, right, 0.08);
}
logSection('pad (Am F C G)');

// --- 2. arpeggio ------------------------------------------------------------
// Same chords, but the engine's arpeggiator walks them: up-down, two octaves,
// ten steps a second, half-gate staccato.
E.patch({
  osc1_wave: waveId('saw'),
  osc2_wave: waveId('square'),
  osc2_mix: 0.35,
  cutoff: 5200,
  resonance: 1.4,
  attack: 0.004,
  decay: 0.22,
  sustain: 0.0,
  release: 0.25,
  delay_mix: 0.25,
  delay_feedback: 0.38,
  reverb_mix: 0.45,
  arp_on: 1,
  arp_mode: arpModeId('updown'),
  arp_rate: 10,
  arp_octaves: 2,
  arp_gate: 0.5,
  arp_latch: 0,
  master: 0.65,
});
const arpBefore = E.arpSteps();
for (const step of PROGRESSION) {
  for (const n of step.pad) E.noteOn(n, 100);
  E.renderInto(left, right, 1.0);
  for (const n of step.pad) E.noteOff(n);
  E.renderInto(left, right, 0.06);
}
console.log(`  ${'arpeggio'.padEnd(22)}        arp took ${E.arpSteps() - arpBefore} steps`);
logSection('arpeggio (up-down x2)');

// --- 3. bass ----------------------------------------------------------------
// Octave down, square through the soft clipper, short notes.
E.patch({
  osc1_wave: waveId('square'),
  osc2_mix: 0,
  filter_type: 0,
  cutoff: 720,
  resonance: 2.6,
  attack: 0.003,
  decay: 0.18,
  sustain: 0.35,
  release: 0.12,
  delay_mix: 0.1,
  reverb_mix: 0.15,
  drive: 0.8,
  drive_mix: 1.0,
  arp_on: 0,
  master: 0.65,
});
for (const step of PROGRESSION) {
  E.noteOn(step.root, 110);
  E.renderInto(left, right, 0.52);
  E.noteOff(step.root);
  E.renderInto(left, right, 0.08);
}
logSection('bass (driven)');

// --- 4. outro ---------------------------------------------------------------
// One big chord, then let the reverb ring out.
E.patch({
  osc1_wave: waveId('saw'),
  osc2_wave: waveId('saw'),
  osc2_mix: 0.6,
  osc1_detune: -9,
  osc2_detune: 9,
  cutoff: 4200,
  resonance: 0.9,
  attack: 0.05,
  decay: 0.5,
  sustain: 0.8,
  release: 0.9,
  delay_mix: 0.22,
  reverb_size: 1.0,
  reverb_mix: 0.9,
  drive: 0.15,
  drive_mix: 0.3,
  arp_on: 0,
  master: 0.22,
});
for (const n of [48, 60, 64, 67]) E.noteOn(n, 100);
E.renderInto(left, right, 1.3);
for (const n of [48, 60, 64, 67]) E.noteOff(n);
E.renderInto(left, right, 2.2); // release plus the reverb tail
logSection('outro + reverb tail');

// --- write ------------------------------------------------------------------
const seconds = left.length / SR;
const buf = encodeWav([Float32Array.from(left), Float32Array.from(right)], SR);
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, buf);
console.log(
  `\nwrote ${outPath}  (${seconds.toFixed(2)} s stereo @ ${SR} Hz, ${(buf.length / 1024).toFixed(0)} KB)`,
);
