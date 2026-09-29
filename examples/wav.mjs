// Minimal WAV writer/reader plus two measurement helpers, so the offline
// examples can prove what they rendered instead of just producing a file.
//
// Only plain 16-bit PCM is written (what every player reads); the reader is
// there so the tests can parse a render back and measure it.

/** Encode float channels (each -1..1) into a 16-bit PCM WAV file. */
export function encodeWav(channels, sampleRate) {
  const n = channels[0].length;
  const nc = channels.length;
  const dataSize = n * nc * 2;
  const buf = Buffer.alloc(44 + dataSize);
  buf.write('RIFF', 0, 'ascii');
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write('WAVE', 8, 'ascii');
  buf.write('fmt ', 12, 'ascii');
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(nc, 22);
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * nc * 2, 28);
  buf.writeUInt16LE(nc * 2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write('data', 36, 'ascii');
  buf.writeUInt32LE(dataSize, 40);
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < nc; c++) {
      const v = Math.max(-1, Math.min(1, channels[c][i]));
      buf.writeInt16LE(Math.round(v * 32767), o);
      o += 2;
    }
  }
  return buf;
}

/** Parse a 16-bit PCM WAV back into float channels. */
export function decodeWav(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('not a WAV file');
  }
  let pos = 12;
  let fmt = null;
  let data = null;
  while (pos + 8 <= buf.length) {
    const id = buf.toString('ascii', pos, pos + 4);
    const size = buf.readUInt32LE(pos + 4);
    const body = pos + 8;
    if (id === 'fmt ') {
      fmt = {
        channels: buf.readUInt16LE(body + 2),
        sampleRate: buf.readUInt32LE(body + 4),
        bits: buf.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      data = { start: body, size };
    }
    pos = body + size + (size % 2);
  }
  if (!fmt || !data) throw new Error('WAV is missing fmt or data chunk');
  if (fmt.bits !== 16) throw new Error(`expected 16-bit samples, got ${fmt.bits}`);
  const frameBytes = fmt.channels * 2;
  const frames = Math.floor(data.size / frameBytes);
  const channels = Array.from({ length: fmt.channels }, () => new Float32Array(frames));
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < fmt.channels; c++) {
      channels[c][i] = buf.readInt16LE(data.start + i * frameBytes + c * 2) / 32768;
    }
  }
  return { sampleRate: fmt.sampleRate, channels, frames };
}

/** Root-mean-square level of a slice. */
export function rms(samples, from = 0, to = samples.length) {
  let s = 0;
  for (let i = from; i < to; i++) s += samples[i] * samples[i];
  return Math.sqrt(s / (to - from));
}

/**
 * Magnitude at one frequency (Goertzel). Cheap single-bin DFT — the right
 * tool for "is there energy at 440 Hz and at its third harmonic".
 */
export function goertzel(samples, freq, sampleRate) {
  const k = 2 * Math.cos((2 * Math.PI * freq) / sampleRate);
  let s1 = 0;
  let s2 = 0;
  for (let i = 0; i < samples.length; i++) {
    const s0 = samples[i] + k * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return Math.sqrt(Math.max(0, s1 * s1 + s2 * s2 - k * s1 * s2)) / samples.length;
}

/** Rising zero crossings per second — a good fundamental estimate for sines. */
export function zeroCrossRate(samples, sampleRate) {
  let zc = 0;
  for (let i = 1; i < samples.length; i++) {
    if (samples[i - 1] <= 0 && samples[i] > 0) zc++;
  }
  return (zc / samples.length) * sampleRate;
}

/** Seconds until the signal stays below `floor` (tail length). */
export function tailLength(samples, sampleRate, floor = 0.002) {
  const win = Math.max(64, Math.round(sampleRate * 0.02));
  for (let i = samples.length - win; i >= 0; i -= win) {
    if (rms(samples, i, i + win) > floor) {
      return (i + win) / sampleRate;
    }
  }
  return 0;
}
