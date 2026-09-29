// moonsynth rack UI.
//
// All sound comes from the MoonBit wasm engine running in the AudioWorklet;
// this script only ships control events (note on/off, parameter changes) to
// the audio thread and draws what the analyser sees. wasm bytes are fetched
// here and posted to the worklet, because the AudioWorklet global scope of
// some embedded Chromium builds has no fetch/URL.

const state = {
  params: {
    0: 2,    // osc1 wave: saw
    1: -7,   // osc1 detune cents
    2: 3,    // osc2 wave: square
    3: 7,    // osc2 detune cents
    4: 0.5,  // osc2 mix
    5: 0,    // filter: LP
    6: 12000,
    7: 0.8,
    8: 0.01,
    9: 0.15,
    10: 0.6,
    11: 0.25,
    12: 0.22,
    13: 0.3,
    14: 0.18,
    15: 0.7,
    16: 0.70, // reverb room size
    17: 0.35, // reverb damping
    18: 0.0, // reverb wet (off until a preset asks)
    19: 0.8, // reverb stereo width
    20: 0.0, // drive amount (off)
    21: 0.0, // drive mix
    22: 0, // arp off
    23: 8, // arp rate, steps/s
    24: 0, // arp mode: up
    25: 1, // arp octaves
    26: 0.6, // arp gate
    27: 0, // arp latch off
  },
  audio: null,     // { ctx, node, analyser }
  baseOctave: 48,  // C3, MIDI note of the leftmost key
  heldKeys: new Map(), // computer-key -> midi note
};

// ---------------------------------------------------------------------------
// parameter registry

const KNOBS = {
  osc1_detune: { id: 1, label: 'DETUNE', min: -1200, max: 1200, curve: 'lin', fmt: v => (v > 0 ? '+' : '') + v.toFixed(0) + ' ct' },
  osc2_detune: { id: 3, label: 'DETUNE', min: -1200, max: 1200, curve: 'lin', fmt: v => (v > 0 ? '+' : '') + v.toFixed(0) + ' ct' },
  osc2_mix: { id: 4, label: 'MIX 2', min: 0, max: 1, curve: 'lin', fmt: v => (v * 100).toFixed(0) + '%' },
  cutoff: { id: 6, label: 'CUTOFF', min: 20, max: 18000, curve: 'log', fmt: v => (v >= 1000 ? (v / 1000).toFixed(1) + 'k' : v.toFixed(0)) + ' Hz' },
  q: { id: 7, label: 'RESO', min: 0.1, max: 16, curve: 'log', fmt: v => 'Q ' + v.toFixed(2) },
  attack: { id: 8, label: 'ATTACK', min: 0.001, max: 5, curve: 'log', fmt: fmtTime },
  decay: { id: 9, label: 'DECAY', min: 0.005, max: 5, curve: 'log', fmt: fmtTime },
  sustain: { id: 10, label: 'SUSTAIN', min: 0, max: 1, curve: 'lin', fmt: v => (v * 100).toFixed(0) + '%' },
  release: { id: 11, label: 'RELEASE', min: 0.005, max: 6, curve: 'log', fmt: fmtTime },
  delay_time: { id: 12, label: 'TIME', min: 0.02, max: 1, curve: 'log', fmt: fmtTime },
  delay_fb: { id: 13, label: 'FDBK', min: 0, max: 0.85, curve: 'lin', fmt: v => (v * 100).toFixed(0) + '%' },
  delay_mix: { id: 14, label: 'WET', min: 0, max: 1, curve: 'lin', fmt: v => (v * 100).toFixed(0) + '%' },
  reverb_size: { id: 16, label: 'SIZE', min: 0, max: 1, curve: 'lin', fmt: pct },
  reverb_damp: { id: 17, label: 'DAMP', min: 0, max: 1, curve: 'lin', fmt: pct },
  reverb_mix: { id: 18, label: 'WET', min: 0, max: 1, curve: 'lin', fmt: pct },
  drive: { id: 20, label: 'DRIVE', min: 0, max: 1, curve: 'lin', fmt: pct },
  drive_mix: { id: 21, label: 'MIX', min: 0, max: 1, curve: 'lin', fmt: pct },
  arp_rate: { id: 23, label: 'RATE', min: 0.5, max: 40, curve: 'log', fmt: (v) => v.toFixed(1) + '/s' },
  arp_octaves: { id: 25, label: 'OCT', min: 1, max: 4, curve: 'lin', fmt: (v) => String(Math.round(v)), quantize: 1 },
  arp_gate: { id: 26, label: 'GATE', min: 0.05, max: 1, curve: 'lin', fmt: pct },
  master: { id: 15, label: 'MASTER', min: 0, max: 1, curve: 'lin', fmt: v => (v * 100).toFixed(0) + '%' },
};

function pct(v) {
  return (v * 100).toFixed(0) + '%';
}

function fmtTime(v) {
  return v >= 1 ? v.toFixed(2) + ' s' : (v * 1000).toFixed(0) + ' ms';
}

function normToValue(def, t) {
  return def.curve === 'log'
    ? def.min * Math.pow(def.max / def.min, t)
    : def.min + (def.max - def.min) * t;
}
function valueToNorm(def, v) {
  return def.curve === 'log'
    ? Math.log(v / def.min) / Math.log(def.max / def.min)
    : (v - def.min) / (def.max - def.min);
}

function setParam(id, value, { fromPreset = false } = {}) {
  // knobs marked quantize snap to that step (the octave range is 1..4)
  const def = Object.values(KNOBS).find((k) => k.id === id);
  const q = def && def.quantize ? def.quantize : 0;
  const v = q > 0 ? Math.round(value / q) * q : value;
  state.params[id] = v;
  if (state.audio) state.audio.node.port.postMessage({ type: 'param', id, value: v });
  if (!fromPreset) syncControlsFromState();
}

// ---------------------------------------------------------------------------
// knobs

function makeKnob(name) {
  const def = KNOBS[name];
  const wrap = document.createElement('div');
  wrap.className = 'knob-slot';
  const knob = document.createElement('div');
  knob.className = 'knob';
  const cap = document.createElement('div');
  cap.className = 'cap';
  knob.appendChild(cap);
  const label = document.createElement('div');
  label.className = 'knob-label';
  label.textContent = def.label;
  const readout = document.createElement('div');
  readout.className = 'knob-value';
  wrap.append(knob, label, readout);

  function paint() {
    const v = state.params[def.id];
    const t = valueToNorm(def, v);
    cap.style.transform = `translateX(-50%) rotate(${-135 + 270 * t}deg)`;
    cap.style.left = '50%';
    readout.textContent = def.fmt(v);
  }
  knob.dataset.paramId = def.id;
  knob.paint = paint;

  let dragging = false, startY = 0, startT = 0;
  knob.addEventListener('pointerdown', (e) => {
    dragging = true; startY = e.clientY;
    startT = valueToNorm(def, state.params[def.id]);
    knob.setPointerCapture(e.pointerId);
  });
  knob.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    const dy = startY - e.clientY;
    const t = Math.min(1, Math.max(0, startT + dy / 180));
    setParam(def.id, normToValue(def, t));
  });
  knob.addEventListener('pointerup', () => { dragging = false; });
  knob.addEventListener('lostpointercapture', () => { dragging = false; });
  // double-click resets to the init preset value
  knob.addEventListener('dblclick', () => {
    setParam(def.id, PRESETS.init.find(([id]) => id === def.id)?.[1] ?? state.params[def.id]);
  });

  paint();
  return wrap;
}

document.querySelectorAll('.knob-slot[data-knob]').forEach((slot) => {
  slot.replaceWith(makeKnob(slot.dataset.knob));
});

// ---------------------------------------------------------------------------
// wave / filter-type segmented buttons

function paintSegmented() {
  document.querySelectorAll('.wave-select, .type-select').forEach((group) => {
    const id = Number(group.dataset.param);
    group.querySelectorAll('button').forEach((b) => {
      b.classList.toggle('on', Number(b.dataset.value) === state.params[id]);
    });
  });
}
document.querySelectorAll('.wave-select, .type-select').forEach((group) => {
  const id = Number(group.dataset.param);
  group.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    setParam(id, Number(b.dataset.value));
  });
});

function syncControlsFromState() {
  document.querySelectorAll('.knob').forEach((k) => k.paint && k.paint());
  paintSegmented();
  paintArp(); // the arpeggiator panel reads the same param table
}

// ---------------------------------------------------------------------------
// presets

const PRESETS = {
  init: [[0,2],[1,-7],[2,3],[3,7],[4,0.5],[5,0],[6,12000],[7,0.8],[8,0.01],[9,0.15],[10,0.6],[11,0.25],[12,0.22],[13,0.3],[14,0.18],[15,0.7],[16,0.7],[17,0.35],[18,0],[19,0.8],[20,0],[21,0],[22,0],[23,8],[24,0],[25,1],[26,0.6],[27,0]],
  bass: [[0,2],[1,-5],[2,3],[3,5],[4,0.6],[5,0],[6,900],[7,1.2],[8,0.003],[9,0.2],[10,0.4],[11,0.12],[12,0.2],[13,0.2],[14,0.0],[15,0.75],[16,0.5],[17,0.5],[18,0],[19,0.8],[20,0.18],[21,0.5],[22,0],[23,10],[24,0],[25,1],[26,0.5],[27,0]],
  pad: [[0,1],[1,-8],[2,2],[3,1200],[4,0.5],[5,0],[6,3500],[7,0.6],[8,0.8],[9,0.5],[10,0.8],[11,1.6],[12,0.38],[13,0.45],[14,0.35],[15,0.6],[16,0.9],[17,0.25],[18,0.55],[19,1],[20,0],[21,0],[22,0],[23,6],[24,0],[25,1],[26,0.8],[27,0]],
  pluck: [[0,3],[1,0],[2,0],[3,7],[4,0.3],[5,0],[6,2400],[7,2.5],[8,0.002],[9,0.25],[10,0.0],[11,0.3],[12,0.29],[13,0.35],[14,0.22],[15,0.8],[16,0.6],[17,0.45],[18,0.32],[19,0.9],[20,0.12],[21,0.35],[22,0],[23,12],[24,0],[25,2],[26,0.45],[27,0]],
  acid: [[0,2],[1,0],[2,2],[3,5],[4,0.35],[5,0],[6,600],[7,8],[8,0.002],[9,0.18],[10,0.15],[11,0.1],[12,0.25],[13,0.4],[14,0.3],[15,0.7],[16,0.45],[17,0.5],[18,0.15],[19,0.7],[20,0.8],[21,0.9],[22,1],[23,14],[24,0],[25,2],[26,0.35],[27,0]],
};
PRESETS.arp = [[0,1],[1,-12],[2,0],[3,12],[4,0.4],[5,0],[6,4200],[7,1.6],[8,0.004],[9,0.3],[10,0.0],[11,0.35],[12,0.25],[13,0.35],[14,0.22],[15,0.75],[16,0.75],[17,0.3],[18,0.4],[19,0.9],[20,0.1],[21,0.3],[22,1],[23,9],[24,2],[25,2],[26,0.5],[27,0]];
document.querySelectorAll('.preset-list button').forEach((b) => {
  b.addEventListener('click', () => {
    for (const [id, v] of PRESETS[b.dataset.preset]) setParam(id, v, { fromPreset: true });
    syncControlsFromState();
  });
});

// ---------------------------------------------------------------------------
// audio engine

async function startAudio() {
  if (state.audio) return;
  const ctx = new AudioContext();
  await ctx.audioWorklet.addModule('audio-worklet.js');
  const node = new AudioWorkletNode(ctx, 'moon-synth', { outputChannelCount: [2] });
  const bytes = await (await fetch('synth.wasm')).arrayBuffer();
  node.port.postMessage({ type: 'load-wasm', bytes });
  const ready = new Promise((resolve, reject) => {
    node.port.onmessage = (e) => {
      const d = e.data || {};
      if (d.type === 'ready') resolve();
      else if (d.type === 'error') reject(new Error(d.message));
      else if (d.type === 'voices') {
        updateVoices(d.count, d.gated);
        paintArpReadout(d);
        if (d.recSeconds > 0) recReadout.textContent = `录音中… ${d.recSeconds.toFixed(1)} s`;
      } else if (d.type === 'rec-done') {
        onRecordingDone(d);
      }
    };
  });
  await ready;
  const analyser = ctx.createAnalyser();
  analyser.fftSize = 2048;
  analyser.smoothingTimeConstant = 0.75;
  node.connect(analyser);
  analyser.connect(ctx.destination);
  // push the full current patch into the engine
  for (const [id, v] of Object.entries(state.params)) {
    node.port.postMessage({ type: 'param', id: Number(id), value: v });
  }
  state.audio = { ctx, node, analyser };
  document.getElementById('status-text').textContent =
    `音频运行中 — ${ctx.sampleRate} Hz · ${ctx.baseLatency ? (ctx.baseLatency * 1000).toFixed(1) + ' ms 基础延迟' : 'worklet 实时渲染'}`;
  document.getElementById('status-text').classList.add('on');
  document.getElementById('sr-text').textContent = 'engine: MoonBit wasm @ ' + ctx.sampleRate + ' Hz';
  const pb = document.getElementById('power-btn');
  pb.textContent = '● 音频运行中';
  pb.classList.add('playing');
  requestAnimationFrame(drawScope);
}

document.getElementById('power-btn').addEventListener('click', () => {
  startAudio().catch((err) => {
    document.getElementById('status-text').textContent = '音频启动失败: ' + err.message;
  });
});

document.getElementById('panic-btn').addEventListener('click', () => {
  if (state.audio) state.audio.node.port.postMessage({ type: 'panic' });
  state.heldKeys.clear();
  document.querySelectorAll('.key.down').forEach((k) => k.classList.remove('down'));
});

function updateVoices(count, gated) {
  const g = gated === undefined ? count : gated;
  document.getElementById('voice-badge').textContent = `VOICES ${g}/8`;
}

// ---------------------------------------------------------------------------
// keyboard

const NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const isBlack = (n) => [1, 3, 6, 8, 10].includes(((n % 12) + 12) % 12);

function noteLabel(n) {
  return NOTE_NAMES[n % 12] + (Math.floor(n / 12) - 1);
}

function buildKeyboard() {
  const kb = document.getElementById('keyboard');
  kb.innerHTML = '';
  const start = state.baseOctave;
  const end = start + 24;
  const whites = [];
  for (let n = start; n <= end; n++) if (!isBlack(n)) whites.push(n);
  const whiteWidth = 100 / whites.length;
  let wi = 0;
  for (let n = start; n <= end; n++) {
    const key = document.createElement('div');
    key.dataset.note = n;
    if (!isBlack(n)) {
      key.className = 'key';
      key.style.left = wi * whiteWidth + '%';
      key.style.width = whiteWidth + '%';
      key.style.position = 'absolute';
      key.style.top = '6px';
      key.style.bottom = '6px';
      if (n === start || n % 12 === 0) {
        const lab = document.createElement('span');
        lab.className = 'klabel';
        lab.textContent = noteLabel(n);
        key.appendChild(lab);
      }
      wi++;
    } else {
      key.className = 'key black';
      key.style.left = wi * whiteWidth - whiteWidth * 0.31 + '%';
      key.style.width = whiteWidth * 0.62 + '%';
    }
    attachKeyInput(key, n);
    kb.appendChild(key);
  }
  document.getElementById('octave-label').textContent =
    `OCT ${noteLabel(start)}–${noteLabel(end)}`;
}

function attachKeyInput(key, note) {
  key.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    noteOn(note);
    key.setPointerCapture(e.pointerId);
  });
  key.addEventListener('pointerup', () => noteOff(note));
  key.addEventListener('lostpointercapture', () => noteOff(note));
}

function noteOn(note) {
  if (state.audio) state.audio.node.port.postMessage({ type: 'note_on', note, vel: 108 });
  document.querySelectorAll(`.key[data-note="${note}"]`).forEach((k) => k.classList.add('down'));
}
function noteOff(note) {
  if (state.audio) state.audio.node.port.postMessage({ type: 'note_off', note });
  document.querySelectorAll(`.key[data-note="${note}"]`).forEach((k) => k.classList.remove('down'));
}

// computer keyboard: two rows like a DAW
const KEYMAP = {
  a: 0, w: 1, s: 2, e: 3, d: 4, f: 5, t: 6, g: 7, y: 8, h: 9, u: 10, j: 11,
  k: 12, o: 13, l: 14, p: 15, ';': 16,
};
window.addEventListener('keydown', (e) => {
  if (e.repeat || e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  const k = e.key.toLowerCase();
  if (k === 'z') { state.baseOctave = Math.max(24, state.baseOctave - 12); buildKeyboard(); return; }
  if (k === 'x') { state.baseOctave = Math.min(84, state.baseOctave + 12); buildKeyboard(); return; }
  const off = KEYMAP[k];
  if (off === undefined || state.heldKeys.has(k)) return;
  const note = state.baseOctave + off;
  state.heldKeys.set(k, note);
  noteOn(note);
});
window.addEventListener('keyup', (e) => {
  const k = e.key.toLowerCase();
  const note = state.heldKeys.get(k);
  if (note === undefined) return;
  state.heldKeys.delete(k);
  noteOff(note);
});

buildKeyboard();

// ---------------------------------------------------------------------------
// scope / spectrum

const scope = document.getElementById('scope');
const sctx = scope.getContext('2d');
let timeData = null, freqData = null;

function drawScopeIdle() {
  sctx.fillStyle = '#0a0c0f';
  sctx.fillRect(0, 0, scope.width, scope.height);
  sctx.strokeStyle = '#1c2129';
  sctx.beginPath();
  sctx.moveTo(0, scope.height / 2);
  sctx.lineTo(scope.width, scope.height / 2);
  sctx.stroke();
  sctx.fillStyle = '#3a4350';
  sctx.font = '12px Consolas, monospace';
  sctx.fillText('scope idle — start audio', 12, scope.height / 2 - 10);
}
drawScopeIdle();

function drawScope() {
  if (!state.audio) { drawScopeIdle(); return; }
  const a = state.audio.analyser;
  if (!timeData) {
    timeData = new Uint8Array(a.fftSize);
    freqData = new Uint8Array(a.frequencyBinCount);
  }
  a.getByteTimeDomainData(timeData);
  a.getByteFrequencyData(freqData);
  const W = scope.width, H = scope.height;
  sctx.fillStyle = '#0a0c0f';
  sctx.fillRect(0, 0, W, H);
  // spectrum (bottom half)
  const bars = 180;
  const bh = H / 2;
  for (let i = 0; i < bars; i++) {
    // log-spaced bins so the spectrum reads musically
    const t0 = i / bars, t1 = (i + 1) / bars;
    const b0 = Math.floor(Math.pow(a.frequencyBinCount, t0));
    const b1 = Math.max(b0 + 1, Math.floor(Math.pow(a.frequencyBinCount, t1)));
    let peak = 0;
    for (let b = b0; b < b1 && b < freqData.length; b++) peak = Math.max(peak, freqData[b]);
    const h = (peak / 255) * (bh - 6);
    sctx.fillStyle = 'rgba(79, 209, 197, 0.85)';
    sctx.fillRect((i * W) / bars, H - h, W / bars - 1, h);
  }
  // waveform (top half)
  sctx.strokeStyle = '#ff8b3d';
  sctx.lineWidth = 1.6;
  sctx.beginPath();
  const mid = bh / 2 + 4;
  for (let i = 0; i < timeData.length; i += 2) {
    const x = (i / timeData.length) * W;
    const y = mid + ((timeData[i] - 128) / 128) * (bh / 2 - 8);
    i === 0 ? sctx.moveTo(x, y) : sctx.lineTo(x, y);
  }
  sctx.stroke();
  requestAnimationFrame(drawScope);
}

// ---------------------------------------------------------------------------
// offline self test — automated DSP assertions, no ears required

async function runSelfTest() {
  const out = document.getElementById('selftest-out');
  out.textContent = 'running…';
  const log = (s) => { out.textContent += '\n' + s; };
  try {
    const sr = 48000;
    const ctx = new OfflineAudioContext(2, sr * 1.2, sr);
    await ctx.audioWorklet.addModule('audio-worklet.js');
    const node = new AudioWorkletNode(ctx, 'moon-synth', { outputChannelCount: [2] });
    node.connect(ctx.destination);
    const bytes = await (await fetch('synth.wasm')).arrayBuffer();
    node.port.postMessage({ type: 'load-wasm', bytes });
    await new Promise((resolve, reject) => {
      node.port.onmessage = (e) => {
        const d = e.data || {};
        if (d.type === 'ready') resolve();
        else if (d.type === 'error') reject(new Error(d.message));
      };
    });
    // pluck patch: pure sine at C4 so the zero-crossing count pins the
    // fundamental exactly; fast envelope, dry
    for (const [id, v] of [[0, 0], [4, 0.0], [5, 0], [6, 12000], [8, 0.002], [9, 0.2], [10, 0.0], [11, 0.05], [14, 0.0], [15, 0.8]]) {
      node.port.postMessage({ type: 'param', id, value: v });
    }
    node.port.postMessage({ type: 'note_on', note: 60, vel: 120 });
    // Give the worklet thread time to consume the control messages while
    // idle: OfflineAudioContext does not pump the worklet's message queue
    // mid-render, so anything posted here must be handled beforehand.
    // (Envelopes only advance inside process(), so an early note_on does
    // not consume any of the rendered timeline.)
    await new Promise((r) => setTimeout(r, 200));
    const buf = await ctx.startRendering();
    const ch = buf.getChannelData(0);
    const rms = (from, to) => {
      let s = 0;
      for (let i = from; i < to; i++) s += ch[i] * ch[i];
      return Math.sqrt(s / (to - from));
    };
    const hit = rms(0, sr * 0.3 | 0);
    const tail = rms(sr * 1.0 | 0, sr * 1.2 | 0);
    let zc = 0;
    for (let i = 1; i < sr * 0.1; i++) if (ch[i - 1] <= 0 && ch[i] > 0) zc++;
    // C4 = 261.6 Hz → ~26 rising crossings in 0.1 s
    log(`attack rms:   ${hit.toFixed(4)}  (want > 0.02)`);
    log(`tail rms:     ${tail.toFixed(5)}  (want < 0.001)`);
    log(`crossings/s:  ${zc * 10}  (want 230–290 ≈ C4 sine)`);
    const pass = hit > 0.02 && tail < 0.001 && zc > 20 && zc < 34;
    out.textContent = (pass ? 'SELF TEST: PASS ✓' : 'SELF TEST: FAIL ✗') + '\n' + out.textContent;
  } catch (err) {
    out.textContent = 'SELF TEST ERROR: ' + (err && err.message || err);
  }
}

document.getElementById('selftest-btn').addEventListener('click', runSelfTest);

// ---------------------------------------------------------------------------
// arpeggiator panel

const arpToggle = document.getElementById('arp-toggle');
const arpLatch = document.getElementById('arp-latch');
const arpReadout = document.getElementById('arp-readout');

arpToggle.addEventListener('click', () => {
  const on = state.params[22] < 0.5;
  setParam(22, on ? 1 : 0);
  paintArp();
});
arpLatch.addEventListener('change', () => setParam(27, arpLatch.checked ? 1 : 0));
document.getElementById('arp-modes').addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  setParam(24, Number(b.dataset.value));
  paintArp();
});

function paintArp() {
  const on = state.params[22] >= 0.5;
  arpToggle.textContent = on ? 'ARP ON' : 'ARP OFF';
  arpToggle.classList.toggle('on', on);
  arpLatch.checked = state.params[27] >= 0.5;
  const mode = Math.round(state.params[24]);
  document.querySelectorAll('#arp-modes button').forEach((b) => {
    b.classList.toggle('on', Number(b.dataset.value) === mode);
  });
}
paintArp();

function paintArpReadout(d) {
  arpReadout.textContent = `steps ${d.arpSteps} · held ${d.held} · gated ${d.gated}`;
}

// ---------------------------------------------------------------------------
// recording: capture the engine output and hand back a WAV

let recorder = null;

/** 16-bit PCM WAV from float channels (the offline examples use the same shape). */
function encodeWav(channels, sampleRate) {
  const n = channels[0].length;
  const nc = channels.length;
  const dataSize = n * nc * 2;
  const buf = new ArrayBuffer(44 + dataSize);
  const v = new DataView(buf);
  const ascii = (off, s) => { for (let i = 0; i < s.length; i++) v.setUint8(off + i, s.charCodeAt(i)); };
  ascii(0, 'RIFF');
  v.setUint32(4, 36 + dataSize, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  v.setUint32(16, 16, true);
  v.setUint16(20, 1, true);
  v.setUint16(22, nc, true);
  v.setUint32(24, sampleRate, true);
  v.setUint32(28, sampleRate * nc * 2, true);
  v.setUint16(32, nc * 2, true);
  v.setUint16(34, 16, true);
  ascii(36, 'data');
  v.setUint32(40, dataSize, true);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < nc; c++) {
      const s = Math.max(-1, Math.min(1, channels[c][i]));
      v.setInt16(o, Math.round(s * 32767), true);
      o += 2;
    }
  }
  return buf;
}

const recBtn = document.getElementById('rec-btn');
const recReadout = document.getElementById('rec-readout');

recBtn.addEventListener('click', () => {
  if (!state.audio) {
    recReadout.textContent = '先点「启动音频」再录音';
    return;
  }
  if (!recorder) {
    recorder = { startedAt: performance.now() };
    state.audio.node.port.postMessage({ type: 'rec-start' });
    recBtn.classList.add('on');
    recBtn.textContent = '⏹ 停止并保存';
    recReadout.textContent = '录音中… 0.0 s';
    return;
  }
  state.audio.node.port.postMessage({ type: 'rec-stop' });
  recBtn.classList.remove('on');
  recBtn.textContent = '⏺ 录音';
});

function onRecordingDone(d) {
  const seconds = d.left.length / d.sampleRate;
  recorder = null;
  if (seconds < 0.1) {
    recReadout.textContent = '录音太短，已丢弃';
    return;
  }
  const wav = encodeWav([d.left, d.right], d.sampleRate);
  const blob = new Blob([wav], { type: 'audio/wav' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `moonsynth-${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}.wav`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  recReadout.textContent =
    `已保存 ${seconds.toFixed(1)} s / ${(wav.byteLength / 1024).toFixed(0)} KB（${d.sampleRate} Hz 立体声）`;
}

// ---------------------------------------------------------------------------
// MIDI input: hardware keyboards drive the same note_on/note_off path

const MIDI_CC = { 1: 6, 74: 7, 7: 15, 11: 18, 12: 14, 13: 20 }; // CC -> param id
const midiBtn = document.getElementById('midi-btn');
const midiReadout = document.getElementById('midi-readout');
const midiHeld = new Set();

midiBtn.addEventListener('click', async () => {
  if (!navigator.requestMIDIAccess) {
    midiReadout.textContent = '此浏览器不支持 Web MIDI';
    return;
  }
  // the first request can take a moment (permission prompt), so say so
  midiReadout.textContent = "请求授权中…（浏览器会弹出权限提示）";
  try {
    const access = await navigator.requestMIDIAccess();
    const names = [...access.inputs.values()].map((i) => i.name);
    for (const input of access.inputs.values()) input.onmidimessage = onMidi;
    access.onstatechange = (e) => {
      if (e.port && e.port.type === 'input') e.port.onmidimessage = onMidi;
    };
    midiBtn.classList.add('on');
    midiBtn.textContent = '🎹 MIDI 已连接';
    midiReadout.textContent = names.length
      ? `输入：${names.join(', ')} · CC1 截止 / CC74 共振 / CC7 主控`
      : '已授权，未发现输入设备（接入后自动生效）';
  } catch (err) {
    midiReadout.textContent = 'MIDI 授权被拒绝：' + (err && err.message ? err.message : err);
  }
});

function onMidi(msg) {
  const [status, d1, d2] = msg.data;
  const cmd = status & 0xf0;
  if (cmd === 0x90 && d2 > 0) {
    midiHeld.add(d1);
    if (state.audio) state.audio.node.port.postMessage({ type: 'note_on', note: d1, vel: d2 });
    flashKey(d1, true);
  } else if (cmd === 0x80 || (cmd === 0x90 && d2 === 0)) {
    midiHeld.delete(d1);
    if (state.audio) state.audio.node.port.postMessage({ type: 'note_off', note: d1 });
    flashKey(d1, false);
  } else if (cmd === 0xb0 && MIDI_CC[d1] !== undefined) {
    const id = MIDI_CC[d1];
    const def = Object.values(KNOBS).find((k) => k.id === id);
    if (!def) return;
    const t = d2 / 127;
    const value = def.curve === 'log' ? def.min * Math.pow(def.max / def.min, t) : def.min + (def.max - def.min) * t;
    setParam(id, value, { fromPreset: true });
    syncControlsFromState();
  }
}

function flashKey(note, on) {
  document.querySelectorAll(`.key[data-note="${note}"]`).forEach((k) => {
    k.classList.toggle('down', on);
  });
  if (on && note >= state.baseOctave && note <= state.baseOctave + 24) {
    setTimeout(() => { if (!midiHeld.has(note)) flashKey(note, false); }, 200);
  }
}
