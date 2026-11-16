import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { avatarReadFixture } from "./support/avatar-read-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { avatarManifestHeader } from "../src/cloudkit-avatar-reader.mjs";
import { digest } from "../src/public-record-schema.mjs";

test("actual local workerd runtime/authority/edge preserve fixed-length avatar JPEG and private cache204 with real SQL and signatures", { timeout: 30000 }, async () => {
  const f = await avatarReadFixture(); let worker;
  const signInPrivateKeyPEM = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" });
  try {
    worker = await avatarWorker();
    const run = async knownSHA256 => {
      const input = f.input({ knownSHA256 }); delete input.signal;
      const body = { synthetic: "echoes-owned-local-avatar-proof-v1", now: f.clock(), input, tables: sqliteSnapshot(f.db),
        records: [...f.model.records.values(), ...f.model.controls.values()], files: [...f.uploadedBytes].map(([k, v]) => [k, Buffer.from(v).toString("base64")]),
        privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY, signInPrivateKeyPEM };
      return fetch(new URL("/http-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(body) });
    };
    const response = await run();
    if (response.status !== 200) assert.fail("workerd avatar HTTP failed: " + await response.text());
    const manifest = JSON.parse(response.headers.get(avatarManifestHeader)), bytes = new Uint8Array(await response.arrayBuffer());
    assert.equal(response.headers.get("Content-Length"), String(bytes.length)); assert.equal(digest(bytes), manifest.sha256);
    assert.equal(response.headers.get("Cache-Control"), "private, no-store"); assert.equal(response.headers.get("X-Synthetic-Download-Count"), "1");
    const cached = await run(manifest.sha256);
    if (cached.status !== 204) assert.fail("workerd avatar HTTP cache failed: " + await cached.text());
    assert.equal(cached.headers.get("Content-Length"), null); assert.equal((await cached.arrayBuffer()).byteLength, 0);
    assert.equal(cached.headers.get("X-Synthetic-Download-Count"), "0");
    await f.callCommunity(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: true, generation: 0 });
    const denied = await run(manifest.sha256); assert.equal(denied.status, 404);
    assert.deepEqual(await denied.json(), { protocolVersion: 1, error: "AVATAR_READ_NOT_FOUND" });
    assert.equal(denied.headers.get("X-Synthetic-Download-Count"), "0");
  } finally { if (worker) await worker.stop(); f.close(); }
});
