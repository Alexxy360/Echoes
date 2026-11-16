import decoderModule from "@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm";
import encoderModule from "jpeg-encoder-wasm/jpeg_encoder_bg.wasm";
import { AvatarNormalizer } from "./avatar-normalizer.mjs";

// Trusted static modules only; intended for CommunityAuthority, never the edge Worker.
export function createWorkerAvatarNormalizer(isEnabled) {
  return new AvatarNormalizer({ decoderModule, encoderModule, isEnabled });
}
