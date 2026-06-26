// Generates assets/extension-icon.png (512x512) — a neon-green aperture/tunnel
// motif on a near-black field. Pure Node (zlib only), no image libraries.

const zlib = require("zlib");
const fs = require("fs");
const path = require("path");

const W = 512;
const H = 512;
const pixels = Buffer.alloc(W * H * 4);

const cx = W / 2;
const cy = H / 2;
const unit = W * 0.5;

function clamp01(v) {
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const dx = x - cx;
    const dy = y - cy;
    const r = Math.hypot(dx, dy) / unit; // 0 at center, 1 at edge midpoint

    // Concentric rings that tighten toward the center (the "tunnel").
    const ring = Math.pow(Math.max(0, Math.sin(r * Math.PI * 5)), 6);
    // Bright focal glow in the middle.
    const glow = Math.exp(-r * r * 6);
    const intensity = clamp01(ring * 0.9 + glow);

    // Soft vignette so corners fall to near-black.
    const vignette = clamp01(1 - Math.max(0, r - 0.2) * 0.9);

    const baseR = 8;
    const baseG = 14;
    const baseB = 10;

    const red = baseR + intensity * (90 * vignette) + glow * 120;
    const green = baseG + intensity * (235 * vignette) + glow * 20;
    const blue = baseB + intensity * (70 * vignette) + glow * 90;

    const i = (y * W + x) * 4;
    pixels[i] = Math.min(255, Math.round(red));
    pixels[i + 1] = Math.min(255, Math.round(green));
    pixels[i + 2] = Math.min(255, Math.round(blue));
    pixels[i + 3] = 255;
  }
}

// --- Minimal PNG encoder (RGBA, no filtering) ---

const crcTable = (() => {
  const table = new Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, "ascii");
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([length, typeBuf, data, crcBuf]);
}

const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0);
ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 6; // color type: RGBA
ihdr[10] = 0; // compression
ihdr[11] = 0; // filter
ihdr[12] = 0; // interlace

const raw = Buffer.alloc(H * (1 + W * 4));
for (let y = 0; y < H; y++) {
  const rowStart = y * (1 + W * 4);
  raw[rowStart] = 0; // filter type 0 (none)
  pixels.copy(raw, rowStart + 1, y * W * 4, (y + 1) * W * 4);
}
const idat = zlib.deflateSync(raw, { level: 9 });

const png = Buffer.concat([
  signature,
  chunk("IHDR", ihdr),
  chunk("IDAT", idat),
  chunk("IEND", Buffer.alloc(0)),
]);

const outPath = path.join(__dirname, "..", "assets", "extension-icon.png");
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, png);
console.log(`Wrote ${outPath} (${png.length} bytes)`);
