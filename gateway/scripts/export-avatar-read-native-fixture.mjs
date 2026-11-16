// Actual reader -> native wire fixture; entirely synthetic accounts/keys/provider responses.
// No session, signing key, asset URL or upload receipt is exported.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { avatarReadFixture } from "../test/support/avatar-read-fixture.mjs";
const destination = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-read/", import.meta.url);
const f = await avatarReadFixture();
try {
  await mkdir(destination, { recursive: true });
  const variants = {};
  for (const variant of ["image", "thumbnail"]) {
    const response = await f.read({ variant });
    assert.equal(response.status, 200);
    const manifest = JSON.parse(response.headers.get("X-Echoes-Avatar-Manifest"));
    const bytes = new Uint8Array(await response.arrayBuffer());
    assert.equal(bytes.length, manifest.byteCount);
    const before = f.downloads.length;
    const cached = await f.read({ variant, knownSHA256: manifest.sha256 });
    assert.equal(cached.status, 204); assert.equal((await cached.arrayBuffer()).byteLength, 0);
    assert.equal(f.downloads.length, before);
    variants[variant] = {
      query: { ownerID: manifest.ownerID, versionID: manifest.versionID, variant, coordinate: f.coordinate },
      downloaded: { status: response.status, headers: Object.fromEntries(response.headers) },
      revalidated: { status: cached.status, headers: Object.fromEntries(cached.headers) }
    };
    await writeFile(new URL(variant + ".jpg", destination), bytes);
  }
  await writeFile(new URL("wire.json", destination), JSON.stringify({
    producer: "CloudKitAvatarReader + SQL policy/registry + checkpoint; synthetic Apple/files/sessions, real Wasm JPEG",
    variants
  }, null, 2) + "\n");
} finally { f.close(); }
