import { readFile } from "node:fs/promises";
import { initSync } from "jpeg-encoder-wasm/pkg/esm/jpeg_encoder.js";
import { encodeJpeg, WasmColorType, WasmSamplingFactor } from "jpeg-encoder-wasm";
let modules;
export function avatarCodecs() {
  modules ??= (async () => Object.freeze({
    decoderModule: await WebAssembly.compile(await readFile(new URL("../../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm", import.meta.url))),
    encoderModule: await WebAssembly.compile(await readFile(new URL("../../node_modules/jpeg-encoder-wasm/pkg/esm/jpeg_encoder_bg.wasm", import.meta.url))),
  }))();
  return modules;
}
export async function avatarImage({ width = 256, height = 128, noise = false } = {}) {
  const { encoderModule } = await avatarCodecs(); initSync({ module: encoderModule });
  const data = new Uint8Array(width * height * 4); let seed = 42;
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const p = (y * width + x) * 4;
    for (let c = 0; c < 3; c++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      data[p + c] = noise ? seed >>> 24 : c === 0 ? x * 255 / width : c === 1 ? y * 255 / height : 110;
    }
    data[p + 3] = 255;
  }
  return encodeJpeg(data, width, height, WasmColorType.Rgba,
    { quality: 80, samplingFactor: WasmSamplingFactor.F_2_2, chromaSubsampling: "average" });
}
export function withAvatarMetadata(bytes) {
  const parts = [bytes.subarray(0, 2)];
  for (const [marker, text] of [[0xe1, "Exif\0\0SYNTHETIC-GPS-CAMERA"], [0xfe, "SYNTHETIC-PRIVATE-COMMENT"], [0xe2, "SYNTHETIC-ICC"]]) {
    const value = new TextEncoder().encode(text), length = value.length + 2;
    parts.push(new Uint8Array([0xff, marker, length >> 8, length & 255]), value);
  }
  parts.push(bytes.subarray(2));
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let p = 0;
  for (const part of parts) { out.set(part, p); p += part.length; } return out;
}
export function markerOffset(bytes, marker) {
  for (let p = 2; p < bytes.length;) {
    if (bytes[p] !== 0xff) throw new Error("fixture marker");
    if (bytes[p + 1] === marker) return p;
    p += 2 + ((bytes[p + 2] << 8) | bytes[p + 3]);
  }
  throw new Error("fixture missing marker");
}
export function invalidAvatarHuffman(bytes) {
  const out = bytes.slice(), at = markerOffset(out, 0xc4), counts = out.subarray(at + 5, at + 21);
  const total = counts.reduce((n, value) => n + value, 0);
  counts.fill(0); counts[0] = 2; counts[1] = total - 2; // Oversubscribed, same bounded segment size.
  return out;
}
