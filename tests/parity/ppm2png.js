// Convert a binary P6 .ppm to .png (viewing aid only).  usage: node ppm2png.js in.ppm out.png
const fs = require('fs'), zlib = require('zlib');
const [inp, out] = process.argv.slice(2);
const b = fs.readFileSync(inp);
let pos = 0; const tok = [];
while (tok.length < 4) {
  while (b[pos] <= 32) pos++;
  let s = pos; while (b[pos] > 32) pos++;
  tok.push(b.toString('latin1', s, pos));
}
pos++;
const w = +tok[1], h = +tok[2];
const raw = Buffer.alloc((w * 3 + 1) * h);
for (let y = 0; y < h; y++) { raw[y * (w * 3 + 1)] = 0; b.copy(raw, y * (w * 3 + 1) + 1, pos + y * w * 3, pos + (y + 1) * w * 3); }
const crcT = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc = (buf) => { let c = -1; for (const x of buf) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
fs.writeFileSync(out, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
