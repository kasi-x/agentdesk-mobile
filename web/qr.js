/* qr.js — minimal QR Code encoder (byte mode, ECC level L, versions 1–10).
 *
 * Dependency-free, zero-network. Ported/compacted from the public QR Code
 * algorithm (Nayuki "qrcodegen", MIT). Supports what the pairing screen
 * needs: arbitrary UTF-8 byte payloads up to 271 bytes (version 10-L).
 *
 * NFR-2.1: this module only builds a boolean module matrix; the caller
 * paints it to a <canvas>. Nothing here touches innerHTML/eval.
 */

const DATA_CODEWORDS = { 1: 19, 2: 34, 3: 55, 4: 80, 5: 108, 6: 136, 7: 156, 8: 194, 9: 232, 10: 274 };
const EC_PER_BLOCK = { 1: 7, 2: 10, 3: 15, 4: 20, 5: 26, 6: 18, 7: 20, 8: 24, 9: 30, 10: 36 };
const NUM_BLOCKS = { 1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 2, 7: 2, 8: 2, 9: 2, 10: 2 };
const ALIGN = {
  1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
  7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
};
const MAX_VERSION = 10;

/* ---- GF(256) arithmetic ---- */
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
(() => {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x = (x << 1) ^ (x & 0x80 ? 0x11d : 0);
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
})();

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return EXP[LOG[a] + LOG[b]];
}

function rsGenerator(degree) {
  let poly = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(poly.length + 1).fill(0);
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= poly[j];
      next[j + 1] ^= gfMul(poly[j], EXP[i]);
    }
    poly = next;
  }
  return poly;
}

function rsEncode(data, ecLen) {
  const gen = rsGenerator(ecLen);
  const rem = new Array(ecLen).fill(0);
  for (const byte of data) {
    const factor = byte ^ rem[0];
    rem.shift();
    rem.push(0);
    for (let i = 0; i < ecLen; i++) rem[i] ^= gfMul(gen[i + 1], factor);
  }
  return rem;
}

/* ---- bit stream ---- */
function toBytes(text) {
  return Array.from(new TextEncoder().encode(String(text)));
}

function chooseVersion(byteLen) {
  for (let v = 1; v <= MAX_VERSION; v++) {
    const countBits = v <= 9 ? 8 : 16;
    if (4 + countBits + byteLen * 8 <= DATA_CODEWORDS[v] * 8) return v;
  }
  throw new Error(`QR: payload too long (${byteLen} bytes)`);
}

function buildCodewords(bytes, version) {
  const bits = [];
  const put = (value, len) => {
    for (let i = len - 1; i >= 0; i--) bits.push((value >>> i) & 1);
  };
  put(0b0100, 4); // byte mode
  put(bytes.length, version <= 9 ? 8 : 16);
  for (const b of bytes) put(b, 8);

  const capBits = DATA_CODEWORDS[version] * 8;
  for (let i = 0; i < 4 && bits.length < capBits; i++) bits.push(0); // terminator
  while (bits.length % 8 !== 0) bits.push(0);

  const dataCw = [];
  for (let i = 0; i < bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
    dataCw.push(b);
  }
  const total = DATA_CODEWORDS[version];
  for (let pad = 0; dataCw.length < total; pad++) dataCw.push(pad % 2 === 0 ? 0xec : 0x11);

  // split into blocks + EC, then interleave
  const nBlocks = NUM_BLOCKS[version];
  const ecLen = EC_PER_BLOCK[version];
  const perBlock = total / nBlocks; // equal split for the supported versions
  const dataBlocks = [];
  const ecBlocks = [];
  for (let i = 0; i < nBlocks; i++) {
    const chunk = dataCw.slice(i * perBlock, (i + 1) * perBlock);
    dataBlocks.push(chunk);
    ecBlocks.push(rsEncode(chunk, ecLen));
  }
  const out = [];
  for (let i = 0; i < perBlock; i++) for (const blk of dataBlocks) out.push(blk[i]);
  for (let i = 0; i < ecLen; i++) for (const blk of ecBlocks) out.push(blk[i]);
  return out;
}

/* ---- module placement ---- */
function makeMatrix(version) {
  const size = 4 * version + 17;
  const mod = Array.from({ length: size }, () => new Array(size).fill(false));
  const fn = Array.from({ length: size }, () => new Array(size).fill(false)); // reserved (function) modules
  const setF = (row, col, dark) => {
    mod[row][col] = !!dark;
    fn[row][col] = true;
  };

  // finder patterns + separators
  const finder = (top, left) => {
    for (let r = -1; r <= 7; r++) {
      for (let c = -1; c <= 7; c++) {
        const rr = top + r;
        const cc = left + c;
        if (rr < 0 || rr >= size || cc < 0 || cc >= size) continue;
        const inRing = r >= 0 && r <= 6 && (c === 0 || c === 6);
        const inTopBottom = (r === 0 || r === 6) && c >= 0 && c <= 6;
        const core = r >= 2 && r <= 4 && c >= 2 && c <= 4;
        setF(rr, cc, inRing || inTopBottom || core);
      }
    }
  };
  finder(0, 0);
  finder(0, size - 7);
  finder(size - 7, 0);

  // timing patterns
  for (let i = 8; i < size - 8; i++) {
    const dark = i % 2 === 0;
    setF(6, i, dark);
    setF(i, 6, dark);
  }

  // alignment patterns
  const pts = ALIGN[version];
  for (const r of pts) {
    for (const c of pts) {
      if ((r === 6 && c === 6) || (r === 6 && c === size - 7) || (r === size - 7 && c === 6)) continue;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const ring = Math.max(Math.abs(dr), Math.abs(dc));
          setF(r + dr, c + dc, ring !== 1);
        }
      }
    }
  }

  // reserve format areas (values written per-mask later)
  for (let i = 0; i <= 8; i++) {
    if (i !== 6) {
      if (!fn[8][i]) setF(8, i, false);
      if (!fn[i][8]) setF(i, 8, false);
    }
  }
  for (let i = 0; i < 8; i++) {
    if (!fn[8][size - 1 - i]) setF(8, size - 1 - i, false);
    if (!fn[size - 1 - i][8]) setF(size - 1 - i, 8, false);
  }

  // version info (v7+)
  if (version >= 7) {
    let rem = version;
    for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
    const bits = (version << 12) | rem;
    for (let i = 0; i < 18; i++) {
      const bit = (bits >>> i) & 1;
      const a = size - 11 + (i % 3);
      const b = Math.floor(i / 3);
      setF(b, a, bit);
      setF(a, b, bit);
    }
  }

  return { size, mod, fn, setF };
}

function placeData(m, codewords) {
  const { size, mod, fn } = m;
  const bits = [];
  for (const cw of codewords) for (let i = 7; i >= 0; i--) bits.push((cw >>> i) & 1);
  let idx = 0;
  let upward = true;
  for (let col = size - 1; col >= 1; col -= 2) {
    if (col === 6) col = 5; // skip the vertical timing column
    for (let i = 0; i < size; i++) {
      const row = upward ? size - 1 - i : i;
      for (const c of [col, col - 1]) {
        if (!fn[row][c]) {
          mod[row][c] = idx < bits.length ? bits[idx] === 1 : false;
          idx++;
        }
      }
    }
    upward = !upward;
  }
}

function maskFn(mask, row, col) {
  switch (mask) {
    case 0: return (row + col) % 2 === 0;
    case 1: return row % 2 === 0;
    case 2: return col % 3 === 0;
    case 3: return (row + col) % 3 === 0;
    case 4: return (Math.floor(row / 2) + Math.floor(col / 3)) % 2 === 0;
    case 5: return ((row * col) % 2) + ((row * col) % 3) === 0;
    case 6: return (((row * col) % 2) + ((row * col) % 3)) % 2 === 0;
    case 7: return (((row + col) % 2) + ((row * col) % 3)) % 2 === 0;
    default: return false;
  }
}

function drawFormat(m, mask) {
  const data = (1 << 3) | mask; // ECC level L → format bits = 01
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  const bits = ((data << 10) | rem) ^ 0x5412;
  const { size, setF } = m;
  const bit = (i) => ((bits >>> i) & 1) !== 0;

  // first copy (around the top-left finder): col 8 rows 0..8, row 8 cols 0..8
  for (let i = 0; i <= 5; i++) setF(i, 8, bit(i));      // col 8, rows 0..5
  setF(7, 8, bit(6));
  setF(8, 8, bit(7));
  setF(8, 7, bit(8));
  for (let i = 9; i < 15; i++) setF(8, 14 - i, bit(i)); // row 8, cols 5..0

  // second copy (row 8 right edge, col 8 bottom edge)
  for (let i = 0; i < 8; i++) setF(8, size - 1 - i, bit(i));
  for (let i = 8; i < 15; i++) setF(size - 15 + i, 8, bit(i));
  setF(size - 8, 8, true); // dark module — always set after the format bits
}

function penalty(m) {
  const { size, mod } = m;
  const N1 = 3, N2 = 3, N3 = 40, N4 = 10;
  let result = 0;

  const countPatterns = (hist) => {
    const n = hist[1];
    const core = n > 0 && hist[2] === n && hist[3] === n * 3 && hist[4] === n && hist[5] === n;
    return (core && hist[0] >= n * 4 && hist[6] >= n ? 1 : 0) +
           (core && hist[6] >= n * 4 && hist[0] >= n ? 1 : 0);
  };
  const addHist = (run, hist) => {
    if (hist[0] === 0) run += size;
    hist.pop();
    hist.unshift(run);
  };

  const scanLine = (getter) => {
    let runColor = false;
    let runLen = 0;
    const hist = [0, 0, 0, 0, 0, 0, 0];
    for (let i = 0; i < size; i++) {
      const c = getter(i);
      if (c === runColor) {
        runLen++;
        if (runLen === 5) result += N1;
        else if (runLen > 5) result++;
      } else {
        addHist(runLen, hist);
        if (!runColor) result += countPatterns(hist) * N3;
        runColor = c;
        runLen = 1;
      }
    }
    if (runColor) {
      addHist(runLen, hist);
      runLen = 0;
    }
    runLen += size;
    addHist(runLen, hist);
    result += countPatterns(hist) * N3;
  };

  for (let y = 0; y < size; y++) scanLine((x) => mod[y][x]);
  for (let x = 0; x < size; x++) scanLine((y) => mod[y][x]);

  for (let y = 0; y < size - 1; y++) {
    for (let x = 0; x < size - 1; x++) {
      const c = mod[y][x];
      if (c === mod[y][x + 1] && c === mod[y + 1][x] && c === mod[y + 1][x + 1]) result += N2;
    }
  }

  let dark = 0;
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (mod[y][x]) dark++;
  const total = size * size;
  const k = Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1;
  result += k * N4;
  return result;
}

/**
 * Encode `text` as a byte-mode QR module matrix.
 * @returns {{size:number, modules:boolean[][]}} modules[row][col] === true → dark
 */
export function qrModules(text) {
  const bytes = toBytes(text);
  const version = chooseVersion(bytes.length);
  const codewords = buildCodewords(bytes, version);
  const size = 4 * version + 17;

  let best = null;
  for (let mask = 0; mask < 8; mask++) {
    const m = makeMatrix(version);
    placeData(m, codewords);
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (!m.fn[r][c] && maskFn(mask, r, c)) m.mod[r][c] = !m.mod[r][c];
      }
    }
    drawFormat(m, mask);
    const score = penalty(m);
    if (!best || score < best.score) best = { score, mod: m.mod };
  }
  return { size, modules: best.mod };
}

/**
 * Paint a QR code for `text` onto a <canvas> 2D context.
 * @param {HTMLCanvasElement} canvas
 * @param {string} text
 * @param {{margin?:number, scale?:number, light?:string, dark?:string}} [opts]
 */
export function renderQr(canvas, text, opts = {}) {
  const { size, modules } = qrModules(text);
  const margin = opts.margin ?? 2;
  const scale = opts.scale ?? 4;
  const dim = (size + margin * 2) * scale;
  canvas.width = dim;
  canvas.height = dim;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  ctx.fillStyle = opts.light ?? '#ffffff';
  ctx.fillRect(0, 0, dim, dim);
  ctx.fillStyle = opts.dark ?? '#0a0a0b';
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      if (modules[r][c]) {
        ctx.fillRect((c + margin) * scale, (r + margin) * scale, scale, scale);
      }
    }
  }
}
