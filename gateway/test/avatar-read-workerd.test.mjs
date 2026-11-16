import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarReadFixture } from "./support/avatar-read-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { avatarManifestHeader } from "../src/cloudkit-avatar-reader.mjs";
import { digest } from "../src/public-record-schema.mjs";

test("real local workerd SQL/auth/policy/signatures protect binary JPEG and cache revalidation with provider models", { timeout: 30000 }, async () => {
  const f = await avatarReadFixture(); let worker;
  try {
    worker = await avatarWorker();
    const run = async knownSHA256 => {
      const input = f.input({ knownSHA256 }); delete input.signal;
      const body = { synthetic: "echoes-owned-local-avatar-proof-v1", now: f.clock(), input, tables: sqliteSnapshot(f.db),
        records: [...f.model.records.values(), ...f.model.controls.values()], files: [...f.uploadedBytes].map(([k, v]) => [k, Buffer.from(v).toString("base64")]),
        privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY };
      return fetch(new URL("/read-proof", worker.origin), { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json", Connection: "close" } });
    };
    const response = await run();
    if (response.status !== 200) assert.fail("workerd reader failed: " + await response.text());
    const manifest = JSON.parse(response.headers.get(avatarManifestHeader));
    assert.equal(digest(new Uint8Array(await response.arrayBuffer())), manifest.sha256);
    assert.equal(response.headers.get("Cache-Control"), "private, no-store"); assert.equal(response.headers.get("X-Synthetic-Download-Count"), "1");
    const cached = await run(manifest.sha256);
    if (cached.status !== 204) assert.fail("workerd revalidation failed: " + await cached.text());
    assert.equal((await cached.arrayBuffer()).byteLength, 0); assert.equal(cached.headers.get("X-Synthetic-Download-Count"), "0");
    await f.callCommunity(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: true, generation: 0 });
    const blocked = await run(manifest.sha256); assert.equal(blocked.status, 400);
    assert.deepEqual(await blocked.json(), { error: "AVATAR_READ_NOT_FOUND", downloadCount: 0 });
  } finally { if (worker) await worker.stop(); f.close(); }
});
