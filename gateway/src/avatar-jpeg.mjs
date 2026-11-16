import { PublicRecordError } from "./public-record-schema.mjs";

/** Narrow intake for iOS-prepared JPEG, before any codec allocation. Not an entropy decoder.
 * Exactly one 8-bit baseline scan, <=512px, bounded tables/segments. Only a fresh canonical JFIF remains.
 */
export function inspectAvatarJPEG(input, { maximumBytes = 256000, maximumPixels = 512 } = {}) {
  if (!(input instanceof Uint8Array) || typeof SharedArrayBuffer !== "undefined" && input.buffer instanceof SharedArrayBuffer ||
      input.byteLength < 4 || input.byteLength > maximumBytes || !Number.isInteger(maximumPixels) || maximumPixels < 1 || maximumPixels > 512 ||
      !Number.isInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 256000) throw new PublicRecordError("PUBLIC_INPUT");
  const bytes = new Uint8Array(input), kept = [new Uint8Array([
    0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
  ])], quant = new Set(), huffman = new Set();
  const fail = () => { throw new PublicRecordError("PUBLIC_INPUT"); };
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) fail();
  const word = at => (bytes[at] << 8) | bytes[at + 1];
  let at = 2, segments = 0, frame, interval = 0, removedMetadata = 0, jfif = false;
  while (at < bytes.length) {
    if (++segments > 64 || bytes[at] !== 0xff) fail();
    const start = at++;
    while (bytes[at] === 0xff) at++;
    const marker = bytes[at++];
    if (at + 2 > bytes.length) fail();
    const length = word(at), payload = at + 2, end = at + length;
    if (length < 2 || end > bytes.length) fail();
    if (marker >= 0xe0 && marker <= 0xef || marker === 0xfe) {
      if (marker === 0xee) fail(); // Adobe RGB/CMYK transforms are outside the prepared-upload contract.
      if (marker === 0xe0 && length >= 16 && bytes[payload] === 74 && bytes[payload + 1] === 70 &&
          bytes[payload + 2] === 73 && bytes[payload + 3] === 70 && bytes[payload + 4] === 0) jfif = true;
      removedMetadata++; at = end; continue;
    }
    if (marker === 0xdb) {
      let p = payload;
      while (p < end) {
        const table = bytes[p++];
        if (table > 3 || quant.has(table) || p + 64 > end) fail();
        quant.add(table);
        for (let i = 0; i < 64; i++) if (bytes[p++] === 0) fail();
      }
      if (p !== end) fail();
    } else if (marker === 0xc4) {
      let p = payload;
      while (p < end) {
        const table = bytes[p++];
        if ((table >> 4) > 1 || (table & 15) > 3 || huffman.has(table) || p + 16 > end) fail();
        let count = 0;
        for (let i = 0; i < 16; i++) count += bytes[p++];
        if (count < 1 || count > 256 || p + count > end) fail();
        p += count; huffman.add(table);
      }
      if (p !== end) fail();
    } else if (marker === 0xc0) {
      if (frame || length < 11 || bytes[payload] !== 8) fail();
      const height = word(payload + 1), width = word(payload + 3), components = bytes[payload + 5];
      if (width < 1 || height < 1 || width > maximumPixels || height > maximumPixels ||
          ![1, 3].includes(components) || length !== 8 + 3 * components) fail();
      const tables = [], base = bytes[payload + 6]; let blocks = 0;
      if (![0, 1].includes(base) || base === 0 && !jfif) fail();
      for (let i = 0; i < components; i++) {
        const p = payload + 6 + 3 * i, sampling = bytes[p + 1];
        if (bytes[p] !== i + base || ![1, 2].includes(sampling >> 4) || ![1, 2].includes(sampling & 15) || bytes[p + 2] > 3) fail();
        blocks += (sampling >> 4) * (sampling & 15);
        tables.push(bytes[p + 2]);
      }
      if (blocks > 10) fail();
      frame = { width, height, components, tables, base };
    } else if (marker === 0xdd) {
      if (length !== 4) fail(); interval = word(payload);
    } else if (marker === 0xda) {
      if (!frame || bytes[payload] !== frame.components || length !== 6 + 2 * frame.components ||
          frame.tables.some(id => !quant.has(id))) fail();
      for (let i = 0; i < frame.components; i++) {
        const p = payload + 1 + i * 2, table = bytes[p + 1];
        if (bytes[p] !== i + frame.base || !huffman.has(table >> 4) || !huffman.has(0x10 | (table & 15))) fail();
      }
      if (bytes[end - 3] !== 0 || bytes[end - 2] !== 63 || bytes[end - 1] !== 0) fail();
      let p = end, restart = 0;
      while (p < bytes.length) {
        if (bytes[p++] !== 0xff) continue;
        while (bytes[p] === 0xff) p++;
        const value = bytes[p++];
        if (value === 0) continue;
        if (value >= 0xd0 && value <= 0xd7) {
          if (!interval || value !== 0xd0 + restart) fail();
          restart = (restart + 1) % 8; continue;
        }
        if (value !== 0xd9 || p !== bytes.length || p <= end + 2) fail();
        kept.push(bytes.subarray(start));
        const size = kept.reduce((n, part) => n + part.byteLength, 0);
        if (size > maximumBytes) fail();
        const clean = new Uint8Array(size);
        let offset = 0;
        for (const part of kept) { clean.set(part, offset); offset += part.byteLength; }
        return Object.freeze({ bytes: clean, width: frame.width, height: frame.height, removedMetadata });
      }
      fail();
    } else fail();
    kept.push(bytes.subarray(start, end)); at = end;
  }
  fail();
}
