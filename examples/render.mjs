// Offline renderer: drive the MoonBit wasm engine from the command line and
// write 16-bit WAV files. This is the library's example program — no
// browser, no audio device, just the engine and a file.
//
//   node examples/render.mjs sine A4 2
//   node examples/render.mjs square C3 1.5 --drive 0.6
//   node examples/render.mjs sine A4 3 --reverb 0.9
//   node examples/render.mjs --chord C4 4 major
//   node examples/render.mjs --scale C4 0.4 minor
//   node examples/render.mjs sine 432 2 --out out/a432.wav
//
// Build the module first:
//   moon build --target wasm --release
//   cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { encodeWav } from './wav.mjs';

const OUT_ADDR = 64 * 1024 * 1024;
const BLOCK = 4096;

const ARP_MODES = { up: 0, down: 1, updown: 2, random: 3, played: 4 };
function arpModeId(name) {
  return ARP_MODES[String(name).toLowerCase()] ?? 0;
}

const WAVES = { sine: 0, tri: 1, saw: 2, square: 3, sqr: 3 };
const CHORDS = {
  major: [0, 4, 7],
  minor: [0, 3, 7],
  maj7: [0, 4, 7, 11],
  min7: [0, 3, 7, 10],
  sus4: [0, 5, 7],
  power: [0, 7],
};
const SCALES = {
  major: [0, 2, 4, 5, 7, 9, 11, 12],
  minor: [0, 2, 3, 5, 7, 8, 10, 12],
  pentatonic: [0, 2, 4, 7, 9, 12],
};

const usage = `usage: node examples/render.mjs <wave> <note|hz> <seconds> [options]
       node examples/render.mjs --chord <note> <seconds> <shape> [--wave w]
       node examples/render.mjs --scale <note> <step-seconds> <shape> [--wave w]

  wave        sine | tri | saw | square
  note        scientific pitch (A4, C#3, Eb5) or a frequency in Hz
  options     --drive 0..1     soft-clip drive
              --reverb 0..1    reverb wet
              --delay 0..1     ping-pong delay wet
              --detune cents   second oscillator offset (adds osc 2)
              --sr hz          sample rate (default 48000)
              --out path       output file (default out/<label>.wav)

  arpeggiator --arp            walk the held notes (a chord arpeggiates; a
                               single note becomes a rhythmic ostinato)
              --arp-mode       up | down | updown | random | played
              --arp-rate n     steps per second (default 8)
              --arp-oct n      octave range 1..4 (default 1)
              --arp-gate 0..1  note length as a fraction of a step (default 0.6)

  waves       sine, tri, saw, square
  chords      ${Object.keys(CHORDS).join(', ')}
  scales      ${Object.keys(SCALES).join(', ')}`;

// --- argument parsing -------------------------------------------------------

const argv = process.argv.slice(2);
if (argv.length === 0 || argv.includes('--help') || argv.includes('-h')) {
  console.log(usage);
  process.exit(argv.length === 0 ? 1 : 0);
}

function takeSwitch(name) {
  const i = argv.indexOf('--' + name);
  if (i < 0) return false;
  argv.splice(i, 1);
  return true;
}

function takeFlag(name, fallback) {
  const i = argv.indexOf('--' + name);
  if (i < 0) return fallback;
  const v = argv[i + 1];
  argv.splice(i, 2);
  return v;
}

const drive = Number(takeFlag('drive', 0));
const reverb = Number(takeFlag('reverb', 0));
const delay = Number(takeFlag('delay', 0));
const detune = Number(takeFlag('detune', 0));
const sr = Number(takeFlag('sr', 48000));
const outFlag = takeFlag('out', null);
const waveFlag = takeFlag('wave', null);
// --chord / --scale are mode switches; the shape is the last positional
const arpOn = takeSwitch('arp');
const arpModeName = takeFlag('arp-mode', 'up');
const arpRate = Number(takeFlag('arp-rate', 8));
const arpOct = Number(takeFlag('arp-oct', 1));
const arpGate = Number(takeFlag('arp-gate', 0.6));
const isChord = takeSwitch('chord');
const isScale = takeSwitch('scale');

// --- note names → MIDI → Hz ------------------------------------------------

const PITCH = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 };

/** "A4" → 69, "C#3" → 49, "Eb5" → 75. Returns null when unparseable. */
function noteToMidi(text) {
  const m = /^([a-gA-G])([#b]?)(-?\d+)$/.exec(text);
  if (!m) return null;
  const base = PITCH[m[1].toLowerCase()];
  const accidental = m[2] === '#' ? 1 : m[2] === 'b' ? -1 : 0;
  return (Number(m[3]) + 1) * 12 + base + accidental;
}

/** Frequency → nearest MIDI note plus the cents needed to reach it exactly. */
function hzToMidiCents(hz) {
  const exact = 69 + 12 * Math.log2(hz / 440);
  const midi = Math.round(exact);
  return { midi, cents: (exact - midi) * 100 };
}

// --- engine -----------------------------------------------------------------

const wasmPath = new URL('../web/synth.wasm', import.meta.url);
if (!existsSync(wasmPath)) {
  console.error(`web/synth.wasm not found.

Build it first:
  moon build --target wasm --release
  cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm`);
  process.exit(1);
}
const E = (await WebAssembly.instantiate(readFileSync(wasmPath), {})).instance.exports;
E.moon_init(sr);
const view = new Float32Array(E.memory.buffer, OUT_ADDR, BLOCK * 2);

const set = (id, value) => E.set_param(id, value);

/** One oscillator, open filter, envelope that holds while the note is down. */
function patch(wave) {
  set(0, WAVES[wave] ?? 0);
  set(1, detune ? -detune : 0);
  set(2, WAVES[wave] ?? 0);
  set(3, detune);
  set(4, detune ? 1 : 0); // osc2 only participates when detuned
  set(5, 0); // low-pass
  set(6, 18000); // cutoff wide open
  set(7, 0.7); // resonance
  set(8, 0.01); // attack
  set(9, 0.1); // decay
  set(10, 1.0); // sustain: a tone should hold
  set(11, 0.15); // release
  set(12, 0.25); // delay time
  set(13, 0.35); // delay feedback
  set(14, delay);
  set(15, 0.8); // master
  set(16, 0.75); // reverb size
  set(17, 0.3); // reverb damping
  set(18, reverb);
  set(19, 0.8); // reverb stereo width
  set(20, drive);
  set(21, drive > 0 ? 1 : 0);
  set(22, arpOn ? 1 : 0);
  set(23, arpRate);
  set(24, arpModeId(arpModeName));
  set(25, arpOct);
  set(26, arpGate);
  set(27, 0); // latch off: the file should end with silence
}

/** Render `seconds` of engine output, appending into two arrays. */
function renderInto(left, right, seconds) {
  const total = Math.round(seconds * sr);
  for (let done = 0; done < total; done += BLOCK) {
    const n = Math.min(BLOCK, total - done);
    E.render(OUT_ADDR, n);
    for (let i = 0; i < n; i++) {
      left.push(view[i * 2]);
      right.push(view[i * 2 + 1]);
    }
  }
}

/** Let the release and the effect tails finish so the file never cuts off. */
function renderTail(left, right) {
  renderInto(left, right, 0.15 + reverb * 2.5 + delay * 1.5);
}

function write(label, left, right) {
  const path = outFlag ?? `out/${label}.wav`;
  mkdirSync(dirname(path), { recursive: true });
  const buf = encodeWav([Float32Array.from(left), Float32Array.from(right)], sr);
  writeFileSync(path, buf);
  console.log(
    `wrote ${path}  (${(left.length / sr).toFixed(2)} s stereo @ ${sr} Hz, ${buf.length} bytes)`,
  );
}

// --- main -------------------------------------------------------------------

if (isChord) {
  const root = noteToMidi(argv[0] ?? '');
  const hold = Number(argv[1] ?? 3);
  const chordShape = argv[2] ?? 'major';
  if (root === null) {
    console.error(`--chord needs a note name, e.g. --chord C4 3 major`);
    process.exit(1);
  }
  if (!(chordShape in CHORDS)) {
    console.error(`unknown chord shape "${chordShape}" — pick ${Object.keys(CHORDS).join(', ')}`);
    process.exit(1);
  }
  patch(waveFlag ?? 'saw');
  const notes = CHORDS[chordShape].map((iv) => root + iv);
  const left = [];
  const right = [];
  for (const n of notes) E.note_on(n, 110);
  renderInto(left, right, hold);
  for (const n of notes) E.note_off(n);
  renderTail(left, right);
  write(`${argv[0]}-${chordShape}`, left, right);
} else if (isScale) {
  const root = noteToMidi(argv[0] ?? '');
  const hold = Number(argv[1] ?? 0.4);
  const scaleShape = argv[2] ?? 'major';
  if (root === null) {
    console.error(`--scale needs a note name, e.g. --scale C4 0.4 minor`);
    process.exit(1);
  }
  if (!(scaleShape in SCALES)) {
    console.error(`unknown scale shape "${scaleShape}" — pick ${Object.keys(SCALES).join(', ')}`);
    process.exit(1);
  }
  patch(waveFlag ?? 'tri');
  const left = [];
  const right = [];
  for (const iv of SCALES[scaleShape]) {
    E.note_on(root + iv, 110);
    renderInto(left, right, hold);
    E.note_off(root + iv);
    renderInto(left, right, 0.05);
  }
  renderTail(left, right);
  write(`${argv[0]}-${scaleShape}`, left, right);
} else {
  const wave = (argv[0] ?? 'sine').toLowerCase();
  if (!(wave in WAVES)) {
    console.error(`unknown wave "${wave}" — pick one of sine, tri, saw, square`);
    process.exit(1);
  }
  const pitchText = argv[1] ?? 'A4';
  const hold = Number(argv[2] ?? 2);
  let midi;
  let cents = 0;
  if (/^-?\d+(\.\d+)?$/.test(pitchText)) {
    const r = hzToMidiCents(Number(pitchText));
    midi = r.midi;
    cents = r.cents;
  } else {
    midi = noteToMidi(pitchText);
    if (midi === null) {
      console.error(`cannot read "${pitchText}" as a note name or a frequency`);
      process.exit(1);
    }
  }
  patch(wave);
  set(1, (detune ? -detune : 0) + cents);
  const left = [];
  const right = [];
  E.note_on(midi, 110);
  renderInto(left, right, hold);
  E.note_off(midi);
  renderTail(left, right);
  write(`${wave}-${pitchText}`, left, right);
}
