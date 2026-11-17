import decoderModule from "@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm";
import encoderModule from "jpeg-encoder-wasm/jpeg_encoder_bg.wasm";
import { AvatarNormalizer } from "./avatar-normalizer.mjs";

// Instantiate codecs only inside CommunityAuthority. Static modules share the Worker bundle;
// startup/CPU/memory acceptance on hosted Free remains a separate activation prerequisite.
export function createWorkerAvatarNormalizer(isEnabled) {
  return new AvatarNormalizer({ decoderModule, encoderModule, isEnabled });
}
