// Deterministic GIF generator for the GIF loader tests and the parity cases.
//   node tests\parity\mkgif.js tests\data\gif
// A tiny GIF encoder (LZW compressor with clear codes / table-full resets, sub-blocks,
// interlacing, local/global palettes, GCE with disposal / transparency / delay, extensions).
const fs = require('fs');
const path = require('path');

const P8 = [[0, 0, 0], [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255], [0, 255, 255], [255, 255, 255]];
const P4 = [[10, 20, 30], [200, 40, 40], [40, 200, 40], [40, 40, 200]];

function bitsFor(n) { let b = 1; while ((1 << b) < n) b++; return b; }   // palette of n entries -> table size bits

function lzw(indices, minCode, opts = {}) {
  const clear = 1 << minCode, eoi = clear + 1;
  const bytes = [];
  let cur = 0, shift = 0, codeSize = minCode + 1, next = eoi + 1, table = new Map();
  const emit = (code) => {
    cur |= code << shift; shift += codeSize;
    while (shift >= 8) { bytes.push(cur & 255); cur >>>= 8; shift -= 8; }
  };
  const reset = () => { emit(clear); next = eoi + 1; codeSize = minCode + 1; table = new Map(); };
  emit(clear);
  let code = indices[0], since = 0;
  for (let i = 1; i < indices.length; i++) {
    const k = indices[i], key = code * 256 + k;
    const hit = table.get(key);
    if (hit !== undefined && !(opts.clearEvery && since >= opts.clearEvery)) { code = hit; since++; continue; }
    emit(code);
    if (next === 4096 || (opts.clearEvery && since >= opts.clearEvery)) { reset(); since = 0; }
    else {
      if (next >= (1 << codeSize)) codeSize++;
      table.set(key, next++);
      since++;
    }
    code = k;
  }
  emit(code);
  emit(eoi);
  if (shift > 0) bytes.push(cur & 255);
  return bytes;
}

function subBlocks(bytes, size = 255) {
  const out = [];
  for (let i = 0; i < bytes.length; i += size) {
    const part = bytes.slice(i, i + size);
    out.push(part.length, ...part);
  }
  out.push(0);
  return out;
}

const le16 = (v) => [v & 255, (v >> 8) & 255];

function interlace(pixels, w, h) {
  const rows = [];
  for (const [s, st] of [[0, 8], [4, 8], [2, 4], [1, 2]]) for (let y = s; y < h; y += st) rows.push(y);
  const out = [];
  for (const y of rows) out.push(...pixels.slice(y * w, (y + 1) * w));
  return out;
}

// g = {version, w, h, palette (global, may be null), loop, frames: [...]}
// frame = {x, y, w, h, pixels|fill, delay, disposal, trans (index), interlaced, palette (local),
//          minCode (override), blockSize, clearEvery, gce (force), pre (raw bytes before the GCE)}
function encode(g) {
  const out = [...Buffer.from(g.version || 'GIF89a')];
  out.push(...le16(g.w), ...le16(g.h));
  const gp = g.palette;
  out.push(gp ? (0x80 | 0x70 | (bitsFor(gp.length) - 1)) : 0x70, 0, 0);
  if (gp) for (const c of gp) out.push(...c);
  if (g.loop !== undefined) out.push(0x21, 0xFF, 11, ...Buffer.from('NETSCAPE2.0'), 3, 1, ...le16(g.loop), 0);
  for (const f of g.frames) {
    if (f.pre) out.push(...f.pre);
    const fw = f.w === undefined ? g.w : f.w, fh = f.h === undefined ? g.h : f.h;
    if (f.gce !== false && (f.gce || f.delay !== undefined || f.disposal !== undefined || f.trans !== undefined)) {
      out.push(0x21, 0xF9, 4, ((f.disposal || 0) << 2) | (f.trans !== undefined ? 1 : 0), ...le16(f.delay || 0), f.trans || 0, 0);
    }
    out.push(0x2C, ...le16(f.x || 0), ...le16(f.y || 0), ...le16(fw), ...le16(fh));
    const lp = f.palette;
    out.push((lp ? (0x80 | (bitsFor(lp.length) - 1)) : 0) | (f.interlaced ? 0x40 : 0));
    if (lp) for (const c of lp) out.push(...c);
    let px = f.pixels || new Array(fw * fh).fill(f.fill || 0);
    if (f.interlaced) px = interlace(px, fw, fh);
    const pal = lp || gp;
    const minCode = f.minCode || Math.max(2, bitsFor(pal.length));
    out.push(minCode);
    out.push(...(px.length ? subBlocks(lzw(px, minCode, f), f.blockSize || 255) : [0]));
  }
  out.push(0x3B);
  return Buffer.from(out);
}

// Reference model (independent of any decoder): the canvas (0xAARRGGBB) shown for every frame, rebuilt
// from frame 0 with the semantics of the ThorVG loader: disposal 2 clears the previous rectangle to 0,
// disposal 3 frames are not drawn unless they are the shown one, a non transparent frame that fits the
// canvas width is copied (even 0 pixels), otherwise only pixels with alpha are drawn.
function model(g) {
  const W = g.w, H = g.h;
  const frames = g.frames.map((f) => {
    const fw = f.w === undefined ? g.w : f.w, fh = f.h === undefined ? g.h : f.h;
    const pal = f.palette || g.palette;
    const colorOf = (i) => (f.trans !== undefined && i === f.trans) || i >= pal.length ? 0
      : ((0xFF000000 | (pal[i][0] << 16) | (pal[i][1] << 8) | pal[i][2]) >>> 0);
    const px = (f.pixels || new Array(fw * fh).fill(f.fill || 0)).map(colorOf);
    return { x: f.x || 0, y: f.y || 0, w: fw, h: fh, px, disposal: f.disposal || 0, transparent: f.trans !== undefined, delay: f.delay || 0 };
  });
  const blit = (c, f) => {
    if (f.y >= H || f.x >= W) return;
    const endY = Math.min(f.h, H - f.y), endX = Math.min(f.w, W - f.x);
    const copy = !f.transparent && f.x + f.w <= W;
    for (let y = 0; y < endY; y++) {
      for (let x = 0; x < (copy ? f.w : endX); x++) {
        const p = f.px[y * f.w + x];
        if (copy || (p >>> 24) !== 0) c[(f.y + y) * W + f.x + x] = p;
      }
    }
  };
  const canvases = frames.map((_, n) => {
    const c = new Array(W * H).fill(0);
    for (let i = 0; i <= n; i++) {
      if (i > 0 && frames[i - 1].disposal === 2) {
        const p = frames[i - 1];
        if (p.y < H && p.x < W) {
          for (let y = 0; y < Math.min(p.h, H - p.y); y++) for (let x = 0; x < Math.min(p.w, W - p.x); x++) c[(p.y + y) * W + p.x + x] = 0;
        }
      }
      if (i === n || frames[i].disposal !== 3) blit(c, frames[i]);
    }
    return c;
  });
  return { w: W, h: H, delays: frames.map((f) => f.delay), canvases };
}

const files = {};
const models = {};
const add = (name, g) => { files[name] = encode(g); models[name] = model(g); };
const grid = (w, h, fn) => { const a = []; for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) a.push(fn(x, y)); return a; };
const comment = [0x21, 0xFE, 5, ...Buffer.from('hello'), 0];
const plainText = [0x21, 0x01, 12, 0, 0, 0, 0, 4, 0, 4, 0, 1, 1, 0, 1, 2, ...Buffer.from('ab'), 0];

add('single.gif', { version: 'GIF87a', w: 4, h: 4, palette: P4, frames: [{ pixels: grid(4, 4, (x, y) => (x + y) % 4) }] });
add('anim3.gif', { w: 8, h: 8, palette: P8, loop: 0, frames: [
  { fill: 1, delay: 10, pre: comment }, { fill: 2, delay: 20, pre: plainText }, { fill: 3, delay: 30 }] });
add('interlaced.gif', { w: 8, h: 10, palette: P8, frames: [
  { pixels: grid(8, 10, (x, y) => y % 8), interlaced: true, delay: 7 },
  { x: 2, y: 3, w: 4, h: 5, pixels: grid(4, 5, (x, y) => 1 + ((x + y) % 7)), interlaced: true, delay: 9 }] });
add('transparent.gif', { w: 6, h: 6, palette: P8, frames: [
  { fill: 1, delay: 5 },
  { x: 1, y: 1, w: 4, h: 4, pixels: grid(4, 4, (x, y) => (x === 0 || y === 0 || x === 3 || y === 3) ? 0 : 3), trans: 0, disposal: 1, delay: 0 },
  { x: 2, y: 2, w: 2, h: 2, pixels: [4, 5, 5, 4], trans: 5, delay: 12 }] });
add('disp_bg.gif', { w: 6, h: 6, palette: P8, frames: [
  { x: 0, y: 0, w: 4, h: 4, fill: 1, disposal: 2, delay: 3 },
  { x: 2, y: 2, w: 4, h: 4, fill: 2, disposal: 2, delay: 4 },
  { x: 0, y: 3, w: 3, h: 3, fill: 3, disposal: 0, delay: 5 }] });
add('disp_prev.gif', { w: 6, h: 6, palette: P8, frames: [
  { fill: 7, disposal: 1, delay: 1 },
  { x: 1, y: 1, w: 3, h: 3, fill: 1, disposal: 3, delay: 2 },
  { x: 3, y: 3, w: 3, h: 3, fill: 2, disposal: 1, delay: 3 },
  { x: 0, y: 0, w: 2, h: 2, fill: 4, disposal: 3, delay: 4 },
  { x: 4, y: 0, w: 2, h: 2, fill: 5, disposal: 0, delay: 5 }] });
add('disp_prev_last.gif', { w: 4, h: 4, palette: P4, frames: [
  { fill: 1, disposal: 3, delay: 1 }, { x: 1, y: 1, w: 2, h: 2, fill: 2, disposal: 3, delay: 1 },
  { x: 0, y: 2, w: 4, h: 2, fill: 3, trans: 0, disposal: 2, delay: 1 }, { x: 2, y: 0, w: 2, h: 3, fill: 2, delay: 1 }] });
add('local_pal.gif', { w: 4, h: 4, palette: null, frames: [
  { palette: [[255, 0, 0], [0, 255, 0], [0, 0, 255], [9, 9, 9]], pixels: grid(4, 4, (x, y) => (x + 2 * y) % 4), delay: 4 },
  { palette: [[255, 255, 0], [0, 255, 255]], pixels: grid(4, 4, (x, y) => (x ^ y) & 1), delay: 8 },
  { palette: Array.from({ length: 16 }, (_, i) => [i * 16, 255 - i * 16, (i * 37) & 255]), pixels: grid(4, 4, (x, y) => x * 4 + y), delay: 6 }] });
add('global_local.gif', { w: 5, h: 3, palette: P4, frames: [
  { pixels: grid(5, 3, (x, y) => (x + y) % 4), delay: 2 },
  { palette: P8, minCode: 4, pixels: grid(5, 3, (x, y) => (x * 3 + y) % 8), delay: 2 },
  { pixels: grid(5, 3, (x, y) => (x * y) % 4), delay: 2 }] });
add('clip.gif', { w: 5, h: 4, palette: P8, frames: [
  { fill: 7, delay: 1 },
  { x: 3, y: 2, w: 4, h: 4, pixels: grid(4, 4, (x, y) => 1 + (x + y) % 3), disposal: 2, delay: 1 },
  { x: 7, y: 0, w: 2, h: 2, fill: 3, delay: 1 },
  { x: 0, y: 3, w: 5, h: 3, pixels: grid(5, 3, (x, y) => 4 + ((x + y) % 2)), delay: 1 },
  { x: 2, y: 0, w: 4, h: 2, fill: 6, trans: 1, delay: 1 }] });
add('oob_index.gif', { w: 6, h: 4, palette: P4, frames: [
  { fill: 1, delay: 1 },
  { x: 1, y: 1, w: 3, h: 2, pixels: [2, 5, 2, 7, 2, 2], minCode: 3, delay: 1 },
  { x: 4, y: 1, w: 3, h: 2, pixels: [3, 6, 3, 3, 4, 3], minCode: 3, delay: 1 }] });
add('zero_frame.gif', { w: 3, h: 3, palette: P4, frames: [
  { w: 0, h: 0, pixels: [], delay: 1 }, { fill: 2, delay: 2 }] });
add('ext_blocks.gif', { version: 'GIF87a', w: 3, h: 2, palette: P4, frames: [
  { fill: 1, pre: [...comment, ...plainText, 0x21, 0xFF, 3, 1, 2, 3, 2, 9, 9, 0], gce: false }, { fill: 3, pre: comment, gce: false }] });

let seed = 12345;
const rnd = () => { seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff; return seed >> 8; };
const noise = grid(97, 61, () => rnd() & 255);
const stripes = grid(97, 61, (x, y) => ((x >> 3) + (y >> 2)) & 255);
const palette256 = Array.from({ length: 256 }, (_, i) => [(i * 7) & 255, (i * 13 + 5) & 255, (i * 29 + 11) & 255]);
add('big.gif', { w: 97, h: 61, palette: palette256, frames: [
  { pixels: noise, delay: 3 }, { pixels: stripes, delay: 4, blockSize: 17 },
  { pixels: grid(97, 61, () => 9), delay: 5 }] });
add('big_clear.gif', { w: 97, h: 61, palette: palette256, frames: [
  { pixels: noise, clearEvery: 100, blockSize: 7, delay: 1 }, { pixels: stripes, clearEvery: 777, delay: 1, interlaced: true }] });
add('runs_min2.gif', { w: 16, h: 16, palette: P4, frames: [
  { fill: 0, delay: 1 }, { pixels: grid(16, 16, (x, y) => (y < 8 ? 1 : 2)), delay: 1 },
  { pixels: grid(16, 16, (x, y) => (x < y ? 3 : 0)), delay: 1 }] });

const dir = process.argv[2] || 'tests/data/gif';
fs.mkdirSync(dir, { recursive: true });
for (const [name, buf] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), buf);
fs.writeFileSync(path.join(dir, 'expected.json'), JSON.stringify(models));
console.log(Object.keys(files).length + ' gifs written to ' + dir);
