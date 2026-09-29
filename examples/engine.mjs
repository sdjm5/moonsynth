// Shared engine driver for the offline examples.
//
// Loads web/synth.wasm, exposes the parameter table by name, and renders
// blocks into growing arrays. Both the single-tone CLI and the demo-track
// builder use this, so the wasm plumbing lives in one place.
import { readFileSync, existsSync } from 'node:fs';

export const OUT_ADDR = 64 * 1024 * 1024;
export const BLOCK = 4096;

/** Parameter ids, matching the kernel's set_param table. */
export const P = {
  osc1_wave: 0,
  osc1_detune: 1,
  osc2_wave: 2,
  osc2_detune: 3,
  osc2_mix: 4,
  filter_type: 5,
  cutoff: 6,
  resonance: 7,
  attack: 8,
  decay: 9,
  sustain: 10,
  release: 11,
  delay_time: 12,
  delay_feedback: 13,
  delay_mix: 14,
  master: 15,
  reverb_size: 16,
  reverb_damp: 17,
  reverb_mix: 18,
  reverb_width: 19,
  drive: 20,
  drive_mix: 21,
  arp_on: 22,
  arp_rate: 23,
  arp_mode: 24,
  arp_octaves: 25,
  arp_gate: 26,
  arp_latch: 27,
};

export const WAVES = { sine: 0, tri: 1, saw: 2, square: 3, sqr: 3 };
export const ARP_MODES = { up: 0, down: 1, updown: 2, random: 3, played: 4 };

export function waveId(name) {
  return WAVES[String(name).toLowerCase()] ?? 0;
}

export function arpModeId(name) {
  return ARP_MODES[String(name).toLowerCase()] ?? 0;
}

/** Load the module, or explain exactly how to build it. */
export function loadEngine(sr) {
  const wasmPath = new URL('../web/synth.wasm', import.meta.url);
  if (!existsSync(wasmPath)) {
    console.error(`web/synth.wasm not found.

Build it first:
  moon build --target wasm --release
  cp _build/wasm/release/build/src/kernel/kernel.wasm web/synth.wasm`);
    process.exit(1);
  }
  const bytes = readFileSync(wasmPath);
  return WebAssembly.instantiate(bytes, {}).then((m) => makeDriver(m.instance.exports, sr));
}

function makeDriver(E, sr) {
  E.moon_init(sr);
  const view = new Float32Array(E.memory.buffer, OUT_ADDR, BLOCK * 2);

  const driver = {
    E,
    sr,
    set(id, value) {
      E.set_param(id, value);
    },
    /** Set several named parameters at once: set({ cutoff: 800, ... }). */
    patch(params) {
      for (const [name, value] of Object.entries(params)) {
        const id = P[name];
        if (id === undefined) throw new Error(`unknown parameter "${name}"`);
        E.set_param(id, value);
      }
    },
    noteOn(note, vel = 110) {
      E.note_on(note, vel);
    },
    noteOff(note) {
      E.note_off(note);
    },
    panic() {
      E.panic();
    },
    arpSteps() {
      return E.arp_steps();
    },
    /** Render `seconds` of engine output, appending into two arrays. */
    renderInto(left, right, seconds) {
      const total = Math.round(seconds * sr);
      for (let done = 0; done < total; done += BLOCK) {
        const n = Math.min(BLOCK, total - done);
        E.render(OUT_ADDR, n);
        for (let i = 0; i < n; i++) {
          left.push(view[i * 2]);
          right.push(view[i * 2 + 1]);
        }
      }
    },
    /** Render the note release and the effect tails so nothing is cut off. */
    renderTail(left, right, seconds) {
      driver.renderInto(left, right, seconds);
    },
  };
  return driver;
}
