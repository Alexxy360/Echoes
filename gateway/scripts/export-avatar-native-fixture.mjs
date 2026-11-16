import { mkdir, writeFile } from "node:fs/promises";
import { AvatarNormalizer, normalizedAvatarManifest, normalizedAvatarUpload } from "../src/avatar-normalizer.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
import { avatarCodecs, avatarImage, withAvatarMetadata } from "../test/support/avatar-image-fixture.mjs";
const accountID = "64000000-0000-4000-8000-000000000001", versionID = "64000000-0000-4000-8000-000000000002";
const requestID = "64000000-0000-4000-8000-000000000003";
const destination = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-normalized/", import.meta.url);
const normalizer = new AvatarNormalizer({ ...await avatarCodecs(), isEnabled: () => true });
const handle = await normalizer.prepare({ bytes: withAvatarMetadata(await avatarImage()), versionID, requestID, authorize: () => ({ accountID }) });
const context = { ...recordIdentity(accountID, "avatar", versionID), requestID }, manifests = {};
await mkdir(destination, { recursive: true });
for (const variant of ["image", "thumbnail"]) {
  manifests[variant] = normalizedAvatarManifest(handle, variant);
  await writeFile(new URL(variant + ".jpg", destination), normalizedAvatarUpload(handle, context, variant).bytes);
}
await writeFile(new URL("manifests.json", destination), JSON.stringify({ producer: "actual pinned server Wasm codecs; synthetic gradient and metadata only", manifests }, null, 2) + "\n");
