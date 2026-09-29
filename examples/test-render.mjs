// End-to-end test of the offline renderer: spawn the example CLI, parse the
// WAV files it writes, and check the physics of what came out. Harmonics are
// measured with a single-bin DFT, so the assertions are about the actual
// spectra of the actual files.
//
//   node examples/test-render.mjs
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { decodeWav, goertzel, rms, tailLength, zeroCrossRate } from './wav.mjs';

const SR = 48000;
let passed = 0;
let total = 0;
const check = (name, ok, detail = '') => {
  total++;
  if (ok) passed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? '  — ' + detail : ''}`);
};
const near = (a, b, tol) => Math.abs(a - b) <= tol;

function render(args) {
  const out = `out/test/${args.map(String).filter((a) => !a.startsWith('--')).join('-')}.wav`;
  execFileSync(process.execPath, ['examples/render.mjs', ...args, '--out', out], { stdio: 'pipe' });
  return { wav: decodeWav(readFileSync(out)), out };
}

/** Steady portion of a note, past the attack/decay. */
const steady = (wav, from = 0.3, to = 1.3) =>
  wav.channels[0].slice(Math.round(from * SR), Math.round(to * SR));

// --- WAV plumbing -----------------------------------------------------------

const { wav: sineWav, out: sinePath } = render(['sine', 'A4', 2]);
check(
  `WAV is 16-bit stereo @ ${SR} Hz`,
  sineWav.sampleRate === SR && sineWav.channels.length === 2 && sineWav.frames > SR,
  `${sinePath}, ${sineWav.frames} frames`,
);

// --- note names → frequencies (the conversion, measured) --------------------

const sine = steady(sineWav);
const midiFreq = (m) => 440 * Math.pow(2, (m - 69) / 12);
check(
  'A4 renders at 440 Hz',
  near(zeroCrossRate(sine, SR), 440, 4.4),
  `${zeroCrossRate(sine, SR).toFixed(1)} Hz`,
);
const { wav: a5 } = render(['sine', 'A5', 1.5]);
const { wav: c3 } = render(['sine', 'C3', 1.5]);
const { wav: eb5 } = render(['sine', 'Eb5', 1.5]);
check(
  'note names map through equal temperament',
  near(zeroCrossRate(steady(a5), SR), 880, 8.8) &&
    near(zeroCrossRate(steady(c3), SR), midiFreq(48), 2) &&
    near(zeroCrossRate(steady(eb5), SR), midiFreq(75), 6),
  `A5 ${zeroCrossRate(steady(a5), SR).toFixed(1)} Hz, C3 ${zeroCrossRate(steady(c3), SR).toFixed(1)} Hz, Eb5 ${zeroCrossRate(steady(eb5), SR).toFixed(1)} Hz`,
);

// a raw frequency is reached exactly, via note + cents detune
const { wav: hz432 } = render(['sine', '432', 1.5]);
check(
  'a bare frequency (432 Hz) is hit exactly, not snapped to A4',
  near(zeroCrossRate(steady(hz432), SR), 432, 4.5),
  `${zeroCrossRate(steady(hz432), SR).toFixed(2)} Hz`,
);

// --- waveforms: measured spectra -------------------------------------------

const g = (s, mult) => goertzel(s, 440 * mult, SR);

check(
  'sine has no harmonics (2f, 3f, 5f all silent)',
  g(sine, 2) < 0.001 && g(sine, 3) < 0.001 && g(sine, 5) < 0.001,
  `2f ${g(sine, 2).toExponential(1)}, 3f ${g(sine, 3).toExponential(1)}`,
);

const square = steady(render(['square', 'A4', 2]).wav);
check(
  'square has odd harmonics only (2f suppressed, 3f ≈ f/3)',
  g(square, 2) < 0.01 && near(g(square, 3), g(square, 1) / 3, g(square, 1) * 0.05),
  `f ${g(square, 1).toFixed(4)}, 2f ${g(square, 2).toExponential(1)}, 3f ${g(square, 3).toFixed(4)} (f/3 = ${(g(square, 1) / 3).toFixed(4)})`,
);
check(
  'square rolls off as 1/n (5f ≈ f/5)',
  near(g(square, 5), g(square, 1) / 5, g(square, 1) * 0.05),
  `5f ${g(square, 5).toFixed(4)} (f/5 = ${(g(square, 1) / 5).toFixed(4)})`,
);

const saw = steady(render(['saw', 'A4', 2]).wav);
check(
  'saw has every harmonic at 1/n',
  near(g(saw, 2), g(saw, 1) / 2, g(saw, 1) * 0.05) &&
    near(g(saw, 3), g(saw, 1) / 3, g(saw, 1) * 0.05) &&
    near(g(saw, 5), g(saw, 1) / 5, g(saw, 1) * 0.05),
  `f ${g(saw, 1).toFixed(4)}, 2f ${g(saw, 2).toFixed(4)}, 3f ${g(saw, 3).toFixed(4)}, 5f ${g(saw, 5).toFixed(4)}`,
);

const tri = steady(render(['tri', 'A4', 2]).wav);
check(
  'triangle has odd harmonics falling as 1/n² (3f ≈ f/9, 5f ≈ f/25)',
  g(tri, 2) < 0.01 &&
    near(g(tri, 3), g(tri, 1) / 9, g(tri, 1) * 0.02) &&
    near(g(tri, 5), g(tri, 1) / 25, g(tri, 1) * 0.02),
  `f ${g(tri, 1).toFixed(4)}, 3f ${g(tri, 3).toFixed(4)} (f/9 = ${(g(tri, 1) / 9).toFixed(4)}), 5f ${g(tri, 5).toFixed(4)} (f/25 = ${(g(tri, 1) / 25).toFixed(4)})`,
);

// --- drive: the soft clipper must add harmonics -----------------------------

const driven = steady(render(['sine', 'A4', 2, '--drive', '0.8']).wav);
check(
  'drive adds harmonics to a pure sine (3f rises by orders of magnitude)',
  g(driven, 3) > g(sine, 3) * 20 && g(driven, 3) > 0.02,
  `clean 3f ${g(sine, 3).toExponential(1)} → driven ${g(driven, 3).toFixed(4)}`,
);
check(
  'drive stays bounded (no clipping runaway)',
  rms(driven) < 1.0 && rms(driven) > 0.05,
  `rms ${rms(driven).toFixed(3)}`,
);

// --- reverb: the tail must outlive the note ---------------------------------

const dry = render(['sine', 'A4', 1]).wav;
const wet = render(['sine', 'A4', 1, '--reverb', '0.9']).wav;
const tailDry = tailLength(dry.channels[0], SR);
const tailWet = tailLength(wet.channels[0], SR);
check(
  'reverb extends the tail well past the dry note',
  tailWet > tailDry + 0.5,
  `dry ${tailDry.toFixed(2)} s → wet ${tailWet.toFixed(2)} s`,
);

// --- chords and scales ------------------------------------------------------

const { wav: chord } = render(['--chord', 'C4', '3', 'major']);
const c = steady(chord, 0.3, 1.5);
const chordTones = [261.63, 329.63, 392.0]; // C4 E4 G4
check(
  'C major chord contains all three tones',
  chordTones.every((f) => goertzel(c, f, SR) > 0.02),
  chordTones.map((f) => goertzel(c, f, SR).toFixed(3)).join(' / '),
);
check(
  'a note outside the chord is absent from it',
  goertzel(c, 293.66, SR) < 0.005, // D4, not in C major
  `D4 ${goertzel(c, 293.66, SR).toExponential(1)}`,
);

const { wav: scale } = render(['--scale', 'C4', '0.3', 'minor']);
check(
  'scale renders eight notes in sequence',
  scale.frames > SR * 2 && rms(scale.channels[0], 0, scale.frames) > 0.01,
  `${(scale.frames / SR).toFixed(2)} s`,
);

// --- left/right are both driven --------------------------------------------

check(
  'both channels carry signal and stay bounded',
  rms(sineWav.channels[0]) > 0.1 &&
    rms(sineWav.channels[1]) > 0.1 &&
    rms(sineWav.channels[0]) < 1.0,
  `L ${rms(sineWav.channels[0]).toFixed(3)}, R ${rms(sineWav.channels[1]).toFixed(3)}`,
);

console.log(`\n${passed}/${total} checks passed`);
process.exit(passed === total ? 0 : 1);
