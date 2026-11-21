// Deterministic PNG test-file generator (node, zlib only).  usage: node mkpng.js <outdir>
// Covers: gray 1/2/4/8/16, rgb 8/16, palette 1/2/4/8 (+tRNS), gray+alpha 8/16, rgba 8/16,
// all 5 row filters, Adam7 interlace, stored / fixed-huffman / dynamic-huffman deflate.
const fs = require('fs'), zlib = require('zlib'), path = require('path');
const out = process.argv[2] || '.';
fs.mkdirSync(out, { recursive: true });

const crcT = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc = (buf) => { let c = -1; for (const x of buf) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };

// deterministic pseudo pattern, returns [r,g,b,a] in 0..65535
function pix(x, y, w, h) {
  const fx = x / Math.max(1, w - 1), fy = y / Math.max(1, h - 1);
  const r = Math.round(fx * 65535);
  const g = Math.round(fy * 65535);
  const b = ((x >> 2) + (y >> 2)) & 1 ? 65535 : 8000;
  const dx = x - w / 2, dy = y - h / 2;
  const a = Math.round(Math.max(0, Math.min(1, 1.3 - Math.sqrt(dx * dx + dy * dy) / (Math.min(w, h) / 2))) * 65535);
  return [r, g, b, a];
}

function paeth(a, b, c) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); return pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }

// build one scanline of packed samples
function packRow(samples, bits) { // samples: array of ints (each `bits` wide)
  const n = Math.ceil(samples.length * bits / 8), row = Buffer.alloc(n);
  if (bits === 16) { samples.forEach((s, i) => row.writeUInt16BE(s, i * 2)); return row; }
  if (bits === 8) { samples.forEach((s, i) => row[i] = s); return row; }
  samples.forEach((s, i) => { const bit = i * bits, sh = 8 - bits - (bit & 7); row[bit >> 3] |= s << sh; });
  return row;
}

function sampleRow(ct, bits, x0, dx, y, w, h, wsub, pal) {
  const s = [], max = (1 << bits) - 1;
  for (let i = 0, x = x0; i < wsub; i++, x += dx) {
    const [r, g, b, a] = pix(x, y, w, h);
    const q = (v) => bits === 16 ? v : Math.round(v / 65535 * max);
    switch (ct) {
      case 0: s.push(q(g)); break;
      case 2: s.push(q(r), q(g), q(b)); break;
      case 3: s.push((x * 3 + y) % pal); break;
      case 4: s.push(q(r), q(a)); break;
      case 6: s.push(q(r), q(g), q(b), q(a)); break;
    }
  }
  return s;
}

function filterRows(rows, bpp, mode) { // rows: Buffer[]; mode: 'cycle' | 0..4
  const res = []; let prev = Buffer.alloc(rows.length ? rows[0].length : 0);
  rows.forEach((row, yi) => {
    const f = mode === 'cycle' ? yi % 5 : mode, o = Buffer.alloc(row.length + 1); o[0] = f;
    for (let i = 0; i < row.length; i++) {
      const a = i >= bpp ? row[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      const p = f === 0 ? 0 : f === 1 ? a : f === 2 ? b : f === 3 ? (a + b) >> 1 : paeth(a, b, c);
      o[i + 1] = (row[i] - p) & 255;
    }
    res.push(o); prev = row;
  });
  return Buffer.concat(res);
}

const ADAM7 = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]];

function makePng(name, { ct, bits, w, h, interlace = 0, filter = 'cycle', deflate = 'default', trns = false }) {
  const chans = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[ct];
  const bpp = Math.max(1, (chans * bits) >> 3);
  const palN = ct === 3 ? Math.min(1 << bits, 16) : 0;
  let raw;
  if (!interlace) {
    const rows = [];
    for (let y = 0; y < h; y++) rows.push(packRow(sampleRow(ct, bits, 0, 1, y, w, h, w, palN), bits));
    raw = filterRows(rows, bpp, filter);
  } else {
    const parts = [];
    for (const [xs, ys, dx, dy] of ADAM7) {
      const pw = Math.ceil((w - xs) / dx), ph = Math.ceil((h - ys) / dy);
      if (pw <= 0 || ph <= 0) continue;
      const rows = [];
      for (let j = 0; j < ph; j++) rows.push(packRow(sampleRow(ct, bits, xs, dx, ys + j * dy, w, h, pw, palN), bits));
      parts.push(filterRows(rows, bpp, filter));
    }
    raw = Buffer.concat(parts);
  }
  let z;
  if (deflate === 'stored') z = zlib.deflateSync(raw, { level: 0 });
  else if (deflate === 'fixed') z = zlib.deflateSync(raw, { strategy: zlib.constants.Z_FIXED });
  else z = zlib.deflateSync(raw, { level: 9 });
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = bits; ihdr[9] = ct; ihdr[12] = interlace;
  const chunks = [Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr)];
  if (ct === 3) {
    const pl = Buffer.alloc(palN * 3);
    for (let i = 0; i < palN; i++) { pl[i * 3] = (i * 67) & 255; pl[i * 3 + 1] = (i * 131 + 40) & 255; pl[i * 3 + 2] = (255 - i * 29) & 255; }
    chunks.push(chunk('PLTE', pl));
    if (trns) { const t = Buffer.alloc(Math.max(1, palN >> 1)); t.forEach((_, i) => t[i] = i * 40 & 255); chunks.push(chunk('tRNS', t)); }
  }
  if (trns && ct === 0) { const t = Buffer.alloc(2); t.writeUInt16BE(bits === 16 ? 0 : (1 << bits) - 1 >> 1); chunks.push(chunk('tRNS', t)); }
  if (trns && ct === 2) { const t = Buffer.alloc(6); t.writeUInt16BE(bits === 16 ? 0 : 0, 0); chunks.push(chunk('tRNS', t)); }
  // split IDAT in two pieces to exercise multi-chunk streams
  const half = z.length >> 1;
  chunks.push(chunk('IDAT', z.subarray(0, half)), chunk('IDAT', z.subarray(half)), chunk('IEND', Buffer.alloc(0)));
  fs.writeFileSync(path.join(out, name + '.png'), Buffer.concat(chunks));
}

const W = 37, H = 29; // odd sizes on purpose (partial bytes, Adam7 corner cases)
makePng('gray1', { ct: 0, bits: 1, w: W, h: H });
makePng('gray2', { ct: 0, bits: 2, w: W, h: H });
makePng('gray4', { ct: 0, bits: 4, w: W, h: H });
makePng('gray8', { ct: 0, bits: 8, w: W, h: H });
makePng('gray16', { ct: 0, bits: 16, w: W, h: H });
makePng('rgb8', { ct: 2, bits: 8, w: W, h: H });
makePng('rgb16', { ct: 2, bits: 16, w: W, h: H });
makePng('pal1', { ct: 3, bits: 1, w: W, h: H });
makePng('pal2', { ct: 3, bits: 2, w: W, h: H });
makePng('pal4', { ct: 3, bits: 4, w: W, h: H, trns: true });
makePng('pal8', { ct: 3, bits: 8, w: W, h: H, trns: true });
makePng('graya8', { ct: 4, bits: 8, w: W, h: H });
makePng('graya16', { ct: 4, bits: 16, w: W, h: H });
makePng('rgba8', { ct: 6, bits: 8, w: W, h: H });
makePng('rgba16', { ct: 6, bits: 16, w: W, h: H });
makePng('rgba8_adam7', { ct: 6, bits: 8, w: W, h: H, interlace: 1 });
makePng('rgb8_adam7', { ct: 2, bits: 8, w: 5, h: 3, interlace: 1 });
makePng('gray4_adam7', { ct: 0, bits: 4, w: W, h: H, interlace: 1 });
makePng('rgba8_stored', { ct: 6, bits: 8, w: W, h: H, deflate: 'stored' });
makePng('rgba8_fixed', { ct: 6, bits: 8, w: W, h: H, deflate: 'fixed' });
makePng('rgba8_sub', { ct: 6, bits: 8, w: W, h: H, filter: 1 });
makePng('rgba8_up', { ct: 6, bits: 8, w: W, h: H, filter: 2 });
makePng('rgba8_avg', { ct: 6, bits: 8, w: W, h: H, filter: 3 });
makePng('rgba8_paeth', { ct: 6, bits: 8, w: W, h: H, filter: 4 });
makePng('rgba8_big', { ct: 6, bits: 8, w: 200, h: 150 });
makePng('rgb8_trns', { ct: 2, bits: 8, w: W, h: H, trns: true });
console.log('done');
