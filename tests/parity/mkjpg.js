// Deterministic JPEG test-file generator (no dependencies): baseline, extended,
// progressive, subsampling, restart intervals, optimized Huffman tables and a few
// invalid/unsupported streams.  Usage: node mkjpg.js <outdir>
'use strict';
const fs = require('fs');
const path = require('path');
const outDir = process.argv[2] || 'tests/data/jpg';
fs.mkdirSync(outDir, { recursive: true });

const ZZ = [0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,
  35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63];
const QL = [16,11,10,16,24,40,51,61,12,12,14,19,26,58,60,55,14,13,16,24,40,57,69,56,14,17,22,29,51,87,80,62,
  18,22,37,56,68,109,103,77,24,35,55,64,81,104,113,92,49,64,78,87,103,121,120,101,72,92,95,98,112,100,103,99];
const QC = new Array(64).fill(99);
[[17,18,24,47],[18,21,26,66],[24,26,56],[47,66]].forEach((r, y) => r.forEach((v, x) => { QC[y * 8 + x] = v; }));

function range(a, b) { const r = []; for (let i = a; i <= b; i++) r.push(i); return r; }
const STD = {
  dc0: { bits: [0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0], vals: range(0, 11) },
  dc1: { bits: [0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0], vals: range(0, 11) },
  ac0: { bits: [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d], vals: [
    0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,
    0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,
    0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,
    ...range(0x43,0x4a),...range(0x53,0x5a),...range(0x63,0x6a),...range(0x73,0x7a),...range(0x83,0x8a),
    ...range(0x92,0x9a),...range(0xa2,0xaa),...range(0xb2,0xba),...range(0xc2,0xca),...range(0xd2,0xda),
    ...range(0xe1,0xea),...range(0xf1,0xfa)] },
  ac1: { bits: [0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77], vals: [
    0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,0x13,0x22,0x32,0x81,
    0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,
    0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,0x27,0x28,0x29,0x2a,
    ...range(0x35,0x3a),...range(0x43,0x4a),...range(0x53,0x5a),...range(0x63,0x6a),...range(0x73,0x7a),
    ...range(0x82,0x8a),...range(0x92,0x9a),...range(0xa2,0xaa),...range(0xb2,0xba),...range(0xc2,0xca),
    ...range(0xd2,0xda),...range(0xe2,0xea),...range(0xf2,0xfa)] },
};
for (const k of ['ac0', 'ac1']) {
  const t = STD[k];
  const n = t.bits.reduce((a, b) => a + b, 0);
  if (n !== 162 || t.vals.length !== 162 || new Set(t.vals).size !== 162) throw new Error('bad std table ' + k);
}

// ---------------------------------------------------------------- image sources
function lcg(seed) { let s = seed >>> 0; return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s >>> 8; }; }
function makeImage(kind, w, h) {
  const px = new Uint8Array(w * h * 3);
  const rnd = lcg(12345 + w * 31 + h);
  const cx = w * 0.4, cy = h * 0.55, rad = Math.min(w, h) * 0.3;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r, g, b;
    if (kind === 'noise') { r = rnd() & 255; g = rnd() & 255; b = rnd() & 255; }
    else {
      r = (x * 255) / Math.max(1, w - 1); g = (y * 255) / Math.max(1, h - 1); b = 255 - (r + g) / 2;
      const d = Math.hypot(x - cx, y - cy);
      if (d < rad) { r = 250; g = 30 + d * 3; b = 40; }
      if (((x >> 3) + (y >> 3)) % 5 === 0 && x > w / 2) { r = 20; g = 200; b = 230; }
      if (x === (w >> 1)) { r = 255; g = 255; b = 255; }
    }
    const o = (y * w + x) * 3;
    px[o] = Math.max(0, Math.min(255, Math.round(r)));
    px[o + 1] = Math.max(0, Math.min(255, Math.round(g)));
    px[o + 2] = Math.max(0, Math.min(255, Math.round(b)));
  }
  return { w, h, px };
}
function planesOf(img, ncomp) {
  const n = img.w * img.h;
  const P = [];
  for (let c = 0; c < ncomp; c++) P.push(new Float64Array(n));
  for (let i = 0; i < n; i++) {
    const r = img.px[i * 3], g = img.px[i * 3 + 1], b = img.px[i * 3 + 2];
    const y = 0.299 * r + 0.587 * g + 0.114 * b;
    if (ncomp === 1) { P[0][i] = y; continue; }
    P[0][i] = y;
    P[1][i] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128;
    P[2][i] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128;
    if (ncomp === 4) P[3][i] = 255 - y;
  }
  return P;
}

// ---------------------------------------------------------------- DCT / quant
const COS = [];
for (let u = 0; u < 8; u++) { COS.push([]); for (let x = 0; x < 8; x++) COS[u].push(Math.cos(((2 * x + 1) * u * Math.PI) / 16) * (u === 0 ? Math.SQRT1_2 : 1) / 2); }
function fdct(blk) {
  const tmp = new Float64Array(64), out = new Float64Array(64);
  for (let y = 0; y < 8; y++) for (let u = 0; u < 8; u++) { let s = 0; for (let x = 0; x < 8; x++) s += blk[y * 8 + x] * COS[u][x]; tmp[y * 8 + u] = s; }
  for (let u = 0; u < 8; u++) for (let v = 0; v < 8; v++) { let s = 0; for (let y = 0; y < 8; y++) s += tmp[y * 8 + u] * COS[v][y]; out[v * 8 + u] = s; }
  return out;
}
function scaledQ(base, quality) {
  const sc = quality < 50 ? Math.floor(5000 / quality) : 200 - quality * 2;
  return base.map(v => Math.max(1, Math.min(255, Math.floor((v * sc + 50) / 100))));
}

// ---------------------------------------------------------------- frame
function buildFrame(img, o) {
  const samp = o.samp;                       // [[h,v],...]
  const ncomp = samp.length;
  const hmax = Math.max(...samp.map(s => s[0])), vmax = Math.max(...samp.map(s => s[1]));
  const mcusX = Math.ceil(img.w / (8 * hmax)), mcusY = Math.ceil(img.h / (8 * vmax));
  const P = planesOf(img, ncomp);
  const qs = [scaledQ(QL, o.q), scaledQ(QC, o.q)];
  const comps = samp.map((s, c) => {
    const [hi, vi] = s;
    const cw = Math.ceil((img.w * hi) / hmax), ch = Math.ceil((img.h * vi) / vmax);
    const bw = mcusX * hi, bh = mcusY * vi;
    const fx = hmax / hi, fy = vmax / vi;
    const plane = new Float64Array(bw * 8 * bh * 8);
    for (let y = 0; y < bh * 8; y++) for (let x = 0; x < bw * 8; x++) {
      const sx = Math.min(x, cw - 1), sy = Math.min(y, ch - 1);
      let acc = 0;
      for (let j = 0; j < fy; j++) for (let i = 0; i < fx; i++) {
        acc += P[c][Math.min(img.h - 1, sy * fy + j) * img.w + Math.min(img.w - 1, sx * fx + i)];
      }
      plane[y * bw * 8 + x] = acc / (fx * fy);
    }
    const tq = c === 0 || c === 3 ? 0 : 1;
    const q = qs[tq];
    const coefs = new Int32Array(bw * bh * 64);
    const blk = new Float64Array(64);
    for (let by = 0; by < bh; by++) for (let bx = 0; bx < bw; bx++) {
      for (let y = 0; y < 8; y++) for (let x = 0; x < 8; x++) blk[y * 8 + x] = plane[(by * 8 + y) * bw * 8 + bx * 8 + x] - 128;
      const d = fdct(blk);
      const base = (by * bw + bx) * 64;
      for (let k = 0; k < 64; k++) coefs[base + k] = Math.round(d[ZZ[k]] / q[ZZ[k]]);
    }
    return { id: (o.ids || [1, 2, 3, 4])[c], h: hi, v: vi, tq, cw, ch, bw, bh, coefs,
      bwUse: Math.ceil(cw / 8), bhUse: Math.ceil(ch / 8) };
  });
  return { w: img.w, h: img.h, comps, qs, mcusX, mcusY, hmax, vmax };
}

// ---------------------------------------------------------------- tokens
const nbitsOf = v => { let n = 0; while (v) { n++; v >>>= 1; } return n; };
class Toks {
  constructor() { this.t = []; }
  sym(tbl, s) { this.t.push([0, tbl, s]); }
  bits(v, n) { if (n > 0) this.t.push([1, v & ((1 << n) - 1), n]); }
  restart(i) { this.t.push([2, i & 7, 0]); }
}
function unitsOf(fr, scanComps) {
  const units = [];
  if (scanComps.length > 1) {
    for (let my = 0; my < fr.mcusY; my++) for (let mx = 0; mx < fr.mcusX; mx++) {
      const u = [];
      for (const ci of scanComps) { const c = fr.comps[ci];
        for (let by = 0; by < c.v; by++) for (let bx = 0; bx < c.h; bx++) u.push([ci, mx * c.h + bx, my * c.v + by]); }
      units.push(u);
    }
  } else {
    const c = fr.comps[scanComps[0]];
    for (let by = 0; by < c.bhUse; by++) for (let bx = 0; bx < c.bwUse; bx++) units.push([[scanComps[0], bx, by]]);
  }
  return units;
}
const dcKey = ci => 'dc' + (ci === 0 || ci === 3 ? 0 : 1);
const acKey = ci => 'ac' + (ci === 0 || ci === 3 ? 0 : 1);

function encodeScan(fr, sc, dri) {
  const tk = new Toks();
  const pred = fr.comps.map(() => 0);
  let eobrun = 0, be = [];
  const emitEobrun = () => {
    if (eobrun > 0) {
      const nb = nbitsOf(eobrun) - 1;
      tk.sym(sc.acTbl, nb << 4);
      if (nb) tk.bits(eobrun, nb);
      eobrun = 0;
      for (const b of be) tk.bits(b, 1);
      be = [];
    }
  };
  const { Ss, Se, Ah, Al } = sc;
  const prog = sc.prog;
  const blockEnc = (ci, bx, by) => {
    const c = fr.comps[ci];
    const base = (by * c.bw + bx) * 64;
    const co = c.coefs;
    if (!prog) {
      const diff = co[base] - pred[ci]; pred[ci] = co[base];
      const a = Math.abs(diff), nb = nbitsOf(a);
      tk.sym(dcKey(ci), nb); tk.bits(diff < 0 ? diff - 1 : diff, nb);
      let r = 0;
      for (let k = 1; k < 64; k++) {
        const v = co[base + k];
        if (v === 0) { r++; continue; }
        while (r > 15) { tk.sym(acKey(ci), 0xf0); r -= 16; }
        const n = nbitsOf(Math.abs(v));
        tk.sym(acKey(ci), (r << 4) | n); tk.bits(v < 0 ? v - 1 : v, n); r = 0;
      }
      if (r > 0) tk.sym(acKey(ci), 0);
    } else if (Ss === 0) {
      if (Ah === 0) {
        const v = co[base] >> Al;
        const diff = v - pred[ci]; pred[ci] = v;
        const nb = nbitsOf(Math.abs(diff));
        tk.sym(dcKey(ci), nb); tk.bits(diff < 0 ? diff - 1 : diff, nb);
      } else tk.bits((co[base] >> Al) & 1, 1);
    } else if (Ah === 0) {
      let r = 0;
      for (let k = Ss; k <= Se; k++) {
        let t = co[base + k], t2;
        if (t < 0) { t = (-t) >> Al; t2 = ~t; } else { t >>= Al; t2 = t; }
        if (t === 0) { r++; continue; }
        if (eobrun > 0) emitEobrun();
        while (r > 15) { tk.sym(sc.acTbl, 0xf0); r -= 16; }
        const n = nbitsOf(t);
        tk.sym(sc.acTbl, (r << 4) | n); tk.bits(t2, n); r = 0;
      }
      if (r > 0) { eobrun++; if (eobrun === 0x7fff) emitEobrun(); }
    } else {
      const absv = new Array(64).fill(0);
      let eob = 0;
      for (let k = Ss; k <= Se; k++) { absv[k] = Math.abs(co[base + k]) >> Al; if (absv[k] === 1) eob = k; }
      let r = 0, br = [];
      for (let k = Ss; k <= Se; k++) {
        const t = absv[k];
        if (t === 0) { r++; continue; }
        while (r > 15 && k <= eob) {
          emitEobrun(); tk.sym(sc.acTbl, 0xf0); r -= 16;
          for (const b of br) tk.bits(b, 1);
          br = [];
        }
        if (t > 1) { br.push(t & 1); continue; }
        emitEobrun();
        tk.sym(sc.acTbl, (r << 4) | 1);
        tk.bits(co[base + k] < 0 ? 0 : 1, 1);
        for (const b of br) tk.bits(b, 1);
        br = []; r = 0;
      }
      if (r > 0 || br.length > 0) {
        eobrun++; be = be.concat(br);
        if (eobrun === 0x7fff || be.length > 900) emitEobrun();
      }
    }
  };
  const units = unitsOf(fr, sc.comps);
  let rn = 0;
  units.forEach((u, i) => {
    if (dri && i > 0 && i % dri === 0) {
      emitEobrun(); tk.restart(rn++); pred.fill(0);
    }
    for (const [ci, bx, by] of u) blockEnc(ci, bx, by);
  });
  emitEobrun();
  return tk.t;
}

// ---------------------------------------------------------------- Huffman
function genOptimal(freqIn) {
  const freq = freqIn.slice(); freq[256] = 1;
  const size = new Array(257).fill(0), others = new Array(257).fill(-1);
  for (;;) {
    let c1 = -1, v = 1e18;
    for (let i = 0; i <= 256; i++) if (freq[i] && freq[i] <= v) { v = freq[i]; c1 = i; }
    let c2 = -1; v = 1e18;
    for (let i = 0; i <= 256; i++) if (freq[i] && freq[i] <= v && i !== c1) { v = freq[i]; c2 = i; }
    if (c2 < 0) break;
    freq[c1] += freq[c2]; freq[c2] = 0;
    size[c1]++; while (others[c1] >= 0) { c1 = others[c1]; size[c1]++; }
    others[c1] = c2;
    size[c2]++; while (others[c2] >= 0) { c2 = others[c2]; size[c2]++; }
  }
  const bits = new Array(33).fill(0);
  for (let i = 0; i <= 256; i++) if (size[i]) bits[size[i]]++;
  for (let i = 32; i > 16; i--) while (bits[i] > 0) {
    let j = i - 2; while (bits[j] === 0) j--;
    bits[i] -= 2; bits[i - 1]++; bits[j + 1] += 2; bits[j]--;
  }
  let i = 16; while (bits[i] === 0) i--; bits[i]--;
  const vals = [];
  for (let l = 1; l <= 32; l++) for (let j = 0; j < 256; j++) if (size[j] === l) vals.push(j);
  return { bits: bits.slice(1, 17), vals };
}
function codesOf(t) {
  const map = new Map(); let code = 0, k = 0;
  for (let l = 1; l <= 16; l++) { for (let i = 0; i < t.bits[l - 1]; i++) map.set(t.vals[k++], [code++, l]); code <<= 1; }
  return map;
}

class BitW {
  constructor() { this.b = []; this.acc = 0; this.n = 0; }
  put(v, n) {
    for (let i = n - 1; i >= 0; i--) {
      this.acc = (this.acc << 1) | ((v >>> i) & 1); this.n++;
      if (this.n === 8) { this.b.push(this.acc); if (this.acc === 0xff) this.b.push(0); this.acc = 0; this.n = 0; }
    }
  }
  flush() { while (this.n) this.put(1, 1); }
}

function seg(marker, payload) { return [0xff, marker, (payload.length + 2) >> 8, (payload.length + 2) & 255, ...payload]; }
function dht(cls, id, t) { return seg(0xc4, [(cls << 4) | id, ...t.bits, ...t.vals]); }

function writeScanData(toks, optimize, tblsOut) {
  const keys = new Set(toks.filter(t => t[0] === 0).map(t => t[1]));
  const tables = {};
  for (const k of keys) {
    if (optimize) {
      const f = new Array(257).fill(0);
      for (const t of toks) if (t[0] === 0 && t[1] === k) f[t[2]]++;
      tables[k] = genOptimal(f);
    } else tables[k] = STD[k];
  }
  const codes = {};
  for (const k of keys) codes[k] = codesOf(tables[k]);
  const w = new BitW();
  for (const t of toks) {
    if (t[0] === 0) { const c = codes[t[1]].get(t[2]); if (!c) throw new Error('missing code ' + t[1] + ' ' + t[2]); w.put(c[0], c[1]); }
    else if (t[0] === 1) w.put(t[1], t[2]);
    else { w.flush(); w.b.push(0xff, 0xd0 + t[1]); }
  }
  w.flush();
  for (const k of keys) tblsOut.push(dht(k[0] === 'd' ? 0 : 1, +k[2], tables[k]));
  return w.b;
}

// ---------------------------------------------------------------- file assembly
function encode(img, o) {
  o = Object.assign({ q: 75, dri: 0, opt: false, prog: false, sof: 0xc0, ids: null, sep: false, q16: false,
    junk: false, script: null }, o);
  const fr = buildFrame(img, o);
  const n = fr.comps.length;
  const out = [0xff, 0xd8];
  if (o.junk) { out.push(...seg(0xe0, [0x4a,0x46,0x49,0x46,0,1,1,0,0,1,0,1,0,0])); out.push(...seg(0xfe, [...Buffer.from('mkjpg test')])); out.push(...seg(0xe1, [1,2,3,4,5])); }
  for (let t = 0; t < (n > 1 ? 2 : 1); t++) {
    const q = fr.qs[t].map((_, k) => fr.qs[t][ZZ[k]]);
    if (o.q16) out.push(...seg(0xdb, [0x10 | t, ...q.flatMap(v => [v >> 8, v & 255])]));
    else out.push(...seg(0xdb, [t, ...q]));
  }
  const sof = [o.precision || 8, fr.h >> 8, fr.h & 255, fr.w >> 8, fr.w & 255, n];
  fr.comps.forEach(c => sof.push(c.id, (c.h << 4) | c.v, c.tq));
  out.push(...seg(o.prog ? 0xc2 : o.sof, sof));
  if (o.dri) out.push(...seg(0xdd, [o.dri >> 8, o.dri & 255]));
  let scans;
  const all = range(0, n - 1);
  if (o.prog) {
    const mk = (comps, Ss, Se, Ah, Al) => ({ comps, Ss, Se, Ah, Al, prog: true, acTbl: Ss ? acKey(comps[0]) : null });
    if (o.script === 'spectral') {
      scans = [mk(all, 0, 0, 0, 0)];
      for (const c of all) { scans.push(mk([c], 1, 5, 0, 0)); scans.push(mk([c], 6, 63, 0, 0)); }
    } else {
      scans = o.sep ? all.map(c => mk([c], 0, 0, 0, 1)) : [mk(all, 0, 0, 0, 1)];
      scans.push(mk([0], 1, 5, 0, 2));
      for (let c = n - 1; c >= 1; c--) scans.push(mk([c], 1, 63, 0, 1));
      scans.push(mk([0], 6, 63, 0, 2));
      scans.push(mk([0], 1, 63, 2, 1));
      if (o.sep) all.forEach(c => scans.push(mk([c], 0, 0, 1, 0))); else scans.push(mk(all, 0, 0, 1, 0));
      for (let c = n - 1; c >= 1; c--) scans.push(mk([c], 1, 63, 1, 0));
      scans.push(mk([0], 1, 63, 1, 0));
    }
  } else if (o.sep) {
    scans = all.map(c => ({ comps: [c], Ss: 0, Se: 63, Ah: 0, Al: 0, prog: false }));
  } else scans = [{ comps: all, Ss: 0, Se: 63, Ah: 0, Al: 0, prog: false }];
  for (const sc of scans) {
    const toks = encodeScan(fr, sc, o.dri);
    const tbls = [];
    const data = writeScanData(toks, o.opt || o.prog, tbls);
    for (const t of tbls) out.push(...t);
    const sos = [sc.comps.length];
    for (const ci of sc.comps) sos.push(fr.comps[ci].id, (ci === 0 || ci === 3 ? 0 : 0x11));
    sos.push(sc.Ss, sc.Se, (sc.Ah << 4) | sc.Al);
    out.push(...seg(0xda, sos), ...data);
  }
  out.push(0xff, 0xd9);
  return Buffer.from(out);
}

// ---------------------------------------------------------------- catalogue
const S444 = [[1, 1], [1, 1], [1, 1]], S420 = [[2, 2], [1, 1], [1, 1]], S422 = [[2, 1], [1, 1], [1, 1]],
  S440 = [[1, 2], [1, 1], [1, 1]], S1 = [[1, 1]], S4x1 = [[4, 1], [1, 1], [1, 1]];
const files = [];     // {name, buf, w, h}
function add(name, kind, w, h, o) {
  const img = makeImage(kind, w, h);
  files.push({ name, buf: encode(img, o), w, h, img });
}
const SZ = [[1, 1], [7, 5], [16, 16], [17, 17], [37, 29], [53, 37], [64, 64], [200, 150]];
for (const [w, h] of SZ) {
  const t = `${w}x${h}`;
  add(`gray_${t}`, 'smooth', w, h, { samp: S1, q: 80 });
  add(`s444_${t}`, 'smooth', w, h, { samp: S444, q: 90 });
  add(`s420_${t}`, 'smooth', w, h, { samp: S420, q: 75, junk: w === 37 });
  add(`p444_${t}`, 'smooth', w, h, { samp: S444, q: 85, prog: true });
  add(`p420_${t}`, 'smooth', w, h, { samp: S420, q: 75, prog: true });
}
for (const [w, h] of [[17, 17], [53, 37], [200, 150]]) {
  const t = `${w}x${h}`;
  add(`s422_${t}`, 'smooth', w, h, { samp: S422, q: 80 });
  add(`s440_${t}`, 'smooth', w, h, { samp: S440, q: 80 });
  add(`p422_${t}`, 'smooth', w, h, { samp: S422, q: 80, prog: true });
  add(`p440_${t}`, 'smooth', w, h, { samp: S440, q: 80, prog: true });
  add(`pgray_${t}`, 'smooth', w, h, { samp: S1, q: 80, prog: true });
}
add('opt420_200x150', 'smooth', 200, 150, { samp: S420, q: 75, opt: true });
add('opt444_64x64', 'smooth', 64, 64, { samp: S444, q: 95, opt: true });
add('sof1_53x37', 'smooth', 53, 37, { samp: S420, q: 75, sof: 0xc1 });
add('q16_37x29', 'smooth', 37, 29, { samp: S444, q: 60, q16: true });
add('ids012_37x29', 'smooth', 37, 29, { samp: S420, q: 75, ids: [0, 1, 2] });
add('noise444_37x29_q95', 'noise', 37, 29, { samp: S444, q: 95, opt: true });
add('noise420_53x37_q10', 'noise', 53, 37, { samp: S420, q: 10 });
add('noise444_64x64_q100', 'noise', 64, 64, { samp: S444, q: 100, opt: true });
add('noisegray_53x37_q98', 'noise', 53, 37, { samp: S1, q: 98 });
add('pnoise444_37x29_q95', 'noise', 37, 29, { samp: S444, q: 95, prog: true });
add('pnoise420_53x37_q40', 'noise', 53, 37, { samp: S420, q: 40, prog: true });
add('pspec420_53x37', 'smooth', 53, 37, { samp: S420, q: 75, prog: true, script: 'spectral' });
add('pnoisespec444_37x29', 'noise', 37, 29, { samp: S444, q: 95, prog: true, script: 'spectral' });
add('psep420_53x37', 'smooth', 53, 37, { samp: S420, q: 75, prog: true, sep: true });
add('pnoisesep444_37x29', 'noise', 37, 29, { samp: S444, q: 95, prog: true, sep: true });
for (const dri of [1, 3, 5]) {
  add(`dri${dri}_420_53x37`, 'smooth', 53, 37, { samp: S420, q: 75, dri });
  add(`dri${dri}_p420_53x37`, 'smooth', 53, 37, { samp: S420, q: 75, dri, prog: true });
}
add('dri2_gray_37x29', 'smooth', 37, 29, { samp: S1, q: 80, dri: 2 });
add('dri2_pnoise444_37x29', 'noise', 37, 29, { samp: S444, q: 95, dri: 2, prog: true });
add('dri4_p422_200x150', 'smooth', 200, 150, { samp: S422, q: 80, dri: 4, prog: true });
add('dri9_444_64x64', 'smooth', 64, 64, { samp: S444, q: 80, dri: 9 });
add('dri3_sep_420_53x37', 'smooth', 53, 37, { samp: S420, q: 75, dri: 3, sep: true });
files[files.length - 1].bad = true;   // jpgd decodes only the first scan of a multi-scan sequential file
add('sep_420_53x37', 'smooth', 53, 37, { samp: S420, q: 75, sep: true });
files[files.length - 1].bad = true;

// invalid / unsupported streams
function derive(base, name, f) {
  const b = files.find(x => x.name === base);
  files.push({ name, buf: Buffer.from(f(Buffer.from(b.buf))), w: b.w, h: b.h, bad: true });
}
const sofPos = b => { for (let i = 2; i < b.length - 1; i++) if (b[i] === 0xff && (b[i + 1] & 0xf0) === 0xc0 && ![0xc4, 0xc8, 0xcc].includes(b[i + 1])) return i; return -1; };
derive('s420_53x37', 'bad_truncated', b => b.subarray(0, b.length >> 1));
derive('s420_53x37', 'bad_noeoi', b => b.subarray(0, b.length - 2));
derive('p420_53x37', 'bad_ptruncated', b => b.subarray(0, (b.length * 2) / 3 | 0));
derive('s420_53x37', 'bad_corrupt', b => { for (let i = 300; i < b.length - 2; i += 97) b[i] ^= 0x5a; return b; });
derive('p444_53x37', 'bad_pcorrupt', b => { for (let i = 200; i < b.length - 2; i += 131) b[i] ^= 0x35; return b; });
derive('s420_53x37', 'bad_sof9', b => { b[sofPos(b) + 1] = 0xc9; return b; });
derive('s420_53x37', 'bad_sof3', b => { b[sofPos(b) + 1] = 0xc3; return b; });
derive('s420_53x37', 'bad_12bit', b => { b[sofPos(b) + 4] = 12; return b; });
derive('s420_53x37', 'bad_zero', b => { const p = sofPos(b); b[p + 5] = 0; b[p + 6] = 0; return b; });
derive('s420_53x37', 'bad_big', b => { const p = sofPos(b); b[p + 5] = 0xff; b[p + 6] = 0xff; return b; });
files.push({ name: 'bad_soi_only', buf: Buffer.from([0xff, 0xd8, 0xff, 0xd9]), w: 8, h: 8, bad: true });
files.push({ name: 'bad_garbage', buf: Buffer.from([0xff, 0xd8, ...Array.from({ length: 200 }, (_, i) => (i * 73 + 11) & 255)]), w: 8, h: 8, bad: true });
add('cmyk_17x17', 'smooth', 17, 17, { samp: [[1, 1], [1, 1], [1, 1], [1, 1]], q: 75 });
files[files.length - 1].bad = true;
add('x4x1_37x29', 'smooth', 37, 29, { samp: S4x1, q: 75 });
files[files.length - 1].bad = true;

for (const f of files) fs.writeFileSync(path.join(outDir, f.name + '.jpg'), f.buf);
fs.writeFileSync(path.join(outDir, 'index.txt'), files.map(f => `${f.name} ${f.w} ${f.h} ${f.bad ? 'bad' : 'ok'}`).join('\n') + '\n');
// source images (raw RGB) for the PSNR sanity check in tests/test_jpg.nim
console.log(files.length + ' files written to ' + outDir);
