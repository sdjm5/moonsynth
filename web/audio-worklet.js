// AudioWorklet processor that drives the moonsynth wasm engine.
//
// The worklet runs on the real-time audio thread. Wasm bytes are compiled on
// the main thread and shipped over the MessagePort (the AudioWorklet global
// scope of some embedded Chromium builds lacks fetch/URL), instantiated here,
// and driven per process() call: the engine renders one block of interleaved
// stereo samples into linear memory, and we copy it to the output channels.
// Control events (note on/off, parameters) arrive as port messages on this
// same thread and become plain exported-function calls.
//
// Recording taps the same buffer: the engine's output is copied into two
// preallocated capture arrays (allocated once, here, so that starting a
// recording never allocates on the audio thread) and handed back to the main
// thread — sliced to length and transferred — when the take ends.

const OUT_ADDR = 64 * 1024 * 1024; // agreed scratch region in linear memory
const REC_MAX_SECONDS = 60;

class MoonSynth extends AudioWorkletProcessor {
  static get parameterDescriptors() {
    return [];
  }

  constructor() {
    super();
    this.ready = false;
    this.view = null;
    this.w = null;
    this.queue = []; // control events that arrive before wasm is ready
    this.framesSinceReport = 0;
    // capture buffers, allocated up front so recording never allocates
    this.recCap = Math.floor(sampleRate * REC_MAX_SECONDS);
    this.recL = new Float32Array(this.recCap);
    this.recR = new Float32Array(this.recCap);
    this.recording = false;
    this.recPos = 0;

    this.port.onmessage = (e) => {
      const d = e.data || {};
      if (d.type === 'load-wasm') {
        this.load(d.bytes);
      } else if (d.type === 'ready-ping') {
        this.port.postMessage({ type: 'ready-ping', ready: this.ready });
      } else if (d.type === 'rec-start') {
        this.recPos = 0;
        this.recording = true;
        this.port.postMessage({ type: 'rec-started', sampleRate });
      } else if (d.type === 'rec-stop') {
        this.stopRecording();
      } else if (this.ready) {
        this.handle(d);
      } else {
        this.queue.push(d);
      }
    };
  }

  stopRecording() {
    if (!this.recording) return;
    this.recording = false;
    const frames = this.recPos;
    // copy the used portion so the capture buffers can be reused for the
    // next take, then hand the copies over (transferred, not copied again)
    const left = this.recL.slice(0, frames);
    const right = this.recR.slice(0, frames);
    this.recPos = 0;
    this.port.postMessage(
      { type: 'rec-done', sampleRate, left, right },
      [left.buffer, right.buffer],
    );
  }

  async load(bytes) {
    try {
      const { instance } = await WebAssembly.instantiate(bytes, {});
      this.w = instance.exports;
      this.w.moon_init(sampleRate);
      // memory-limits pins the wasm memory, so the buffer never detaches
      // and this view stays valid for the life of the node.
      this.view = new Float32Array(this.w.memory.buffer, OUT_ADDR);
      for (const d of this.queue) this.handle(d);
      this.queue = [];
      this.ready = true;
      this.port.postMessage({ type: 'ready', sampleRate });
    } catch (e) {
      this.port.postMessage({ type: 'error', message: String((e && e.stack) || e) });
    }
  }

  handle(d) {
    if (d.type === 'note_on') this.w.note_on(d.note, d.vel | 0);
    else if (d.type === 'note_off') this.w.note_off(d.note);
    else if (d.type === 'param') this.w.set_param(d.id, d.value);
    else if (d.type === 'panic') this.w.panic();
  }

  process(inputs, outputs) {
    const out = outputs[0];
    const L = out[0];
    const R = out.length > 1 ? out[1] : null;
    if (!this.ready) {
      L.fill(0);
      if (R) R.fill(0);
      return true;
    }
    const n = L.length;
    this.w.render(OUT_ADDR, n);
    for (let i = 0; i < n; i++) {
      L[i] = this.view[i * 2];
      if (R) R[i] = this.view[i * 2 + 1];
    }
    // record the engine output (post-master, exactly what is heard)
    if (this.recording) {
      const room = this.recCap - this.recPos;
      const take = n < room ? n : room;
      for (let i = 0; i < take; i++) {
        this.recL[this.recPos + i] = L[i];
        this.recR[this.recPos + i] = R ? R[i] : L[i];
      }
      this.recPos = this.recPos + take;
      if (this.recPos >= this.recCap) this.stopRecording(); // hit the cap
    }
    // report engine state to the UI about twice a second
    this.framesSinceReport += n;
    if (this.framesSinceReport > sampleRate / 2) {
      this.framesSinceReport = 0;
      this.port.postMessage({
        type: 'voices',
        count: this.w.voice_count(),
        gated: this.w.gated_count(),
        held: this.w.held_count(),
        arpSteps: this.w.arp_steps(),
        recSeconds: this.recording ? this.recPos / sampleRate : 0,
      });
    }
    return true;
  }
}

registerProcessor('moon-synth', MoonSynth);
