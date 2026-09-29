# moonsynth as a library, offline

`src/lib` is a portable MoonBit synthesis library: oscillators with PolyBLEP
antialiasing, a biquad filter, ADSR envelopes, ping-pong delay, Freeverb
reverb and a soft-clip drive, plus an 8-voice engine that wires them
together. `src/kernel` compiles it to a wasm module. This directory drives
that module from Node — no browser, no audio device, no GUI — and writes
16-bit WAV files you can play in anything.

## Build once

```
moon build --target wasm --release
cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm
```

## Render a tone

```
node examples/render.mjs sine   A4   2                    # 2 s of 440 Hz
node examples/render.mjs square C3   1.5 --drive 0.6      # driven square
node examples/render.mjs saw    A3   3   --reverb 0.9     # saw with a long tail
node examples/render.mjs tri    E4   2   --detune 12      # two detuned oscillators
node examples/render.mjs sine   432  2                    # a raw frequency, not a note
node examples/render.mjs --chord C4 3 major               # C E G
node examples/render.mjs --scale C4 0.3 minor             # eight notes in a row
```

Notes are scientific pitch (`A4`, `C#3`, `Eb5`) and are converted with equal
temperament; a bare number is treated as Hz and reached exactly, by picking
the nearest note and applying the remaining cents as oscillator detune.
Files land in `out/` unless `--out` says otherwise.

Options: `--drive`, `--reverb`, `--delay`, `--detune`, `--sr`, `--out`, and
`--wave` for the chord/scale modes. Chords: major, minor, maj7, min7, sus4,
power. Scales: major, minor, pentatonic.

## Verify what came out

```
node examples/test-render.mjs
```

This spawns the CLI, parses the WAV files back and measures them with a
single-bin DFT — the assertions are about the spectra of the actual files,
not about the code path that produced them. Current output:

```
16/16 checks passed
```

What it establishes, with the numbers it measured:

| waveform | measured spectrum | theory |
| --- | --- | --- |
| sine | f 0.346, 2f 8e-16, 3f 6e-7 | a sine has no harmonics |
| square | f 0.441, **2f 1e-16**, 3f 0.147, 5f 0.088 | odd harmonics only, 1/n: f/3 = 0.147, f/5 = 0.088 |
| saw | f 0.221, 2f 0.110, 3f 0.073, 5f 0.044 | every harmonic, 1/n: f/2 = 0.110, f/3 = 0.074, f/5 = 0.044 |
| triangle | f 0.281, 2f 0.003, 3f 0.031, 5f 0.011 | odd harmonics, 1/n²: f/9 = 0.031, f/25 = 0.011 |

The even harmonics of the square and triangle measure at machine epsilon
(1e-16), which is what the PolyBLEP correction is supposed to do: it removes
the aliasing of the discontinuities without introducing harmonics the ideal
waveform does not have. Pitch is checked by zero-crossing rate — A4 → 440.0
Hz, A5 → 880.0 Hz, C3 → 131.0 Hz, Eb5 → 622.0 Hz, 432 Hz → 432.00 Hz — and
the effects are checked by what they change: drive lifts the 3rd harmonic of
a pure sine from 6e-7 to 0.127, reverb stretches a 1 s note into a 2.64 s
file.

## Files

```
render.mjs        the CLI: note/frequency parsing, patch setup, block render, WAV out
test-render.mjs   end-to-end: spawn the CLI, decode the WAVs, measure the spectra
wav.mjs           16-bit PCM WAV encode/decode + rms, Goertzel, zero-crossing, tail length
```
