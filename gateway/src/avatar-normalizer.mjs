import decoderFactory from "@jsquash/jpeg/codec/dec/mozjpeg_dec.js";
import { initEmscriptenModule } from "@jsquash/jpeg/utils.js";
import { initSync as initRustEncoder } from "jpeg-encoder-wasm/pkg/esm/jpeg_encoder.js";
import { encodeJpeg, WasmColorType, WasmSamplingFactor } from "jpeg-encoder-wasm";
import { createHash } from "node:crypto";
import { PublicRecordError, plain, publicUUID, recordIdentity } from "./public-record-schema.mjs";
import { inspectAvatarJPEG } from "./avatar-jpeg.mjs";
import { avatarDescriptor, avatarDescriptorHash } from "./avatar-record-schema.mjs";

const prepared = new WeakMap();
const hash = value => createHash("sha256").update(value).digest("hex");
const codecMemoryLimit = 32 * 1024 * 1024;
class NormalizedAvatar {
  toJSON() { return "<normalized-avatar>"; }
  toString() { return "<normalized-avatar>"; }
}
function variant(value) {
  if (!["image", "thumbnail"].includes(value)) throw new PublicRecordError("PUBLIC_INPUT");
  return value;
}
function item(handle, kind) {
  const value = prepared.get(handle);
  if (!value) throw new PublicRecordError("PUBLIC_SCOPE");
  return { value, part: value[variant(kind)] };
}
/** Exact native manifest contract; caller must authorize disclosure and current profile/policy. */
export function normalizedAvatarManifest(handle, kind) {
  const { value, part } = item(handle, kind);
  return Object.freeze({ schemaVersion: 1, ownerID: value.accountID, versionID: value.versionID, variant: kind,
    byteCount: part.bytes.byteLength, width: part.width, height: part.height, sha256: part.sha256 });
}
/** Only the same reserved owner/version/request may feed the internal asset transport. */
export function normalizedAvatarUpload(handle, context, kind) {
  const { value, part } = item(handle, kind);
  if (context?.accountID !== value.accountID || context.requestID !== value.requestID || context.kind !== "avatar" ||
      context.recordName !== recordIdentity(value.accountID, "avatar", value.versionID).recordName) throw new PublicRecordError("PUBLIC_SCOPE");
  return Object.freeze({ bytes: part.bytes.slice(), sha256: part.sha256 });
}
export function normalizedAvatarPayloadHash(handle) {
  const { value } = item(handle, "image");
  return avatarDescriptorHash(avatarDescriptor({ image: normalizedAvatarManifest(handle, "image"),
    thumbnail: normalizedAvatarManifest(handle, "thumbnail"), requestID: value.requestID }, value.accountID));
}
function thumbnail(image) {
  const ratio = Math.min(1, 128 / Math.max(image.width, image.height));
  const width = Math.max(1, Math.round(image.width * ratio)), height = Math.max(1, Math.round(image.height * ratio));
  const data = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const sx = Math.max(0, Math.min(image.width - 1, (x + 0.5) * image.width / width - 0.5));
    const sy = Math.max(0, Math.min(image.height - 1, (y + 0.5) * image.height / height - 0.5));
    const x0 = Math.floor(sx), y0 = Math.floor(sy), x1 = Math.min(x0 + 1, image.width - 1), y1 = Math.min(y0 + 1, image.height - 1);
    const dx = sx - x0, dy = sy - y0, offset = (y * width + x) * 4;
    for (let c = 0; c < 3; c++) data[offset + c] =
      (image.data[(y0 * image.width + x0) * 4 + c] * (1 - dx) + image.data[(y0 * image.width + x1) * 4 + c] * dx) * (1 - dy) +
      (image.data[(y1 * image.width + x0) * 4 + c] * (1 - dx) + image.data[(y1 * image.width + x1) * 4 + c] * dx) * dy;
    data[offset + 3] = 255;
  }
  return { data, width, height };
}
function ensureImageData() {
  if (globalThis.ImageData !== undefined) {
    if (typeof globalThis.ImageData !== "function") throw new PublicRecordError();
    return;
  }
  // workerd has no Canvas. The codec only needs this bounded pixel value object.
  globalThis.ImageData = class ImageData {
    constructor(data, width, height) {
      if (!(data instanceof Uint8ClampedArray) || !Number.isInteger(width) || !Number.isInteger(height) ||
          width < 1 || height < 1 || width > 512 || height > 512 || data.byteLength !== width * height * 4) throw new PublicRecordError("PUBLIC_INPUT");
      this.data = data; this.width = width; this.height = height;
    }
  };
}

/** One bounded codec operation per instance; trusted host must keep a singleton and bound admission. No networking or URLs.
 * Static, pinned Wasm modules are supplied by the trusted host, never by client payload.
 */
export class AvatarNormalizer {
  #decoderWasm; #encoderWasm; #decoder; #encoder; #busy = false; #warning = false; #enabled;
  constructor({ decoderModule, encoderModule, isEnabled } = {}) {
    if (!(decoderModule instanceof WebAssembly.Module) || !(encoderModule instanceof WebAssembly.Module) ||
        typeof isEnabled !== "function") throw new PublicRecordError("PUBLIC_INPUT");
    this.#decoderWasm = decoderModule; this.#encoderWasm = encoderModule; this.#enabled = isEnabled;
  }
  #check(authorize, expected, signal) {
    if (signal?.aborted || this.#enabled() !== true) throw new PublicRecordError();
    const identity = authorize();
    if (!identity || typeof identity.accountID !== "string" || !publicUUID.test(identity.accountID) ||
        typeof identity.then === "function" || expected !== undefined && identity.accountID !== expected) {
      void identity?.catch?.(() => {}); throw new PublicRecordError("PUBLIC_SCOPE");
    }
    if (signal?.aborted || this.#enabled() !== true) throw new PublicRecordError();
    return identity.accountID;
  }
  #memory(module) {
    const bytes = module?.HEAPU8 instanceof Uint8Array ? module.HEAPU8.byteLength :
      module?.memory instanceof WebAssembly.Memory ? module.memory.buffer.byteLength : undefined;
    if (bytes === undefined || bytes > codecMemoryLimit) throw new PublicRecordError();
  }
  async #codec(encode) {
    const key = encode ? this.#encoder : this.#decoder;
    if (key) return key;
    if (!encode) ensureImageData();
    const module = encode ? initRustEncoder({ module: this.#encoderWasm }) : await initEmscriptenModule(decoderFactory,
      this.#decoderWasm, { print: () => { this.#warning = true; },
        printErr: () => { this.#warning = true; }, onAbort: () => { this.#warning = true; } });
    this.#memory(module);
    if (this.#warning) throw new PublicRecordError();
    if (encode) this.#encoder = module; else this.#decoder = module;
    return module;
  }
  #encode(module, image, kind) {
    this.#warning = false;
    const output = encodeJpeg(image.data, image.width, image.height, WasmColorType.Rgba,
      { quality: kind === "image" ? 80 : 75, samplingFactor: WasmSamplingFactor.F_2_2, chromaSubsampling: "average" });
    this.#memory(module);
    if (this.#warning || !(output instanceof Uint8Array)) throw new PublicRecordError();
    const result = inspectAvatarJPEG(output, { maximumBytes: kind === "image" ? 256000 : 32000,
      maximumPixels: kind === "image" ? 512 : 128 });
    if (result.width !== image.width || result.height !== image.height) throw new PublicRecordError();
    return { bytes: result.bytes, width: result.width, height: result.height, sha256: hash(result.bytes) };
  }
  async prepare(options = {}) {
    if (!plain(options) || Object.keys(options).some(key => !["bytes", "versionID", "requestID", "authorize", "signal"].includes(key))) throw new PublicRecordError("PUBLIC_INPUT");
    const { bytes, versionID, requestID, authorize, signal } = options;
    if (typeof authorize !== "function" || typeof versionID !== "string" || typeof requestID !== "string" ||
        !publicUUID.test(versionID) || !publicUUID.test(requestID)) throw new PublicRecordError("PUBLIC_INPUT");
    if (this.#busy) throw new PublicRecordError("PUBLIC_LIMIT");
    this.#busy = true;
    let input, image, small;
    try {
      const accountID = this.#check(authorize, undefined, signal);
      input = inspectAvatarJPEG(bytes);
      this.#warning = false;
      const decoder = await this.#codec(false); this.#check(authorize, accountID, signal);
      this.#warning = false;
      image = decoder.decode(input.bytes.buffer, false);
      this.#memory(decoder);
      if (this.#warning || !image || image.width !== input.width || image.height !== input.height ||
          !(image.data instanceof Uint8ClampedArray) || image.data.byteLength !== input.width * input.height * 4) throw new PublicRecordError("PUBLIC_INPUT");
      this.#check(authorize, accountID, signal);
      const encoder = await this.#codec(true); this.#check(authorize, accountID, signal);
      const full = this.#encode(encoder, image, "image"); this.#check(authorize, accountID, signal);
      small = thumbnail(image);
      const smallEncoded = this.#encode(encoder, small, "thumbnail"); this.#check(authorize, accountID, signal);
      const handle = Object.freeze(new NormalizedAvatar());
      prepared.set(handle, { accountID, versionID, requestID, image: full, thumbnail: smallEncoded }); return handle;
    } catch (error) {
      // A fatal/warning path must not reuse a possibly aborted or leaking native codec instance.
      this.#decoder = undefined; this.#encoder = undefined;
      throw error instanceof PublicRecordError ? error : new PublicRecordError("PUBLIC_INPUT");
    } finally {
      if (input?.bytes instanceof Uint8Array) input.bytes.fill(0);
      if (image?.data instanceof Uint8ClampedArray) image.data.fill(0);
      if (small?.data instanceof Uint8ClampedArray) small.data.fill(0);
      // Never reuse a native JPEG decoder heap for another request/account.
      this.#decoder = undefined; this.#encoder = undefined; this.#warning = false; this.#busy = false;
    }
  }
}
