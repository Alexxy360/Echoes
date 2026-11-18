import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { setImmediate as tick } from "node:timers/promises";
import { avatarUploadHTTPFixture } from "../test/support/avatar-upload-http-fixture.mjs";
import { CloudKitPublicRetentionProcessor } from "../src/public-retention-processor.mjs";

/** Real local Runtime/HTTP/SQL/codec, synthetic accounts/provider only. No Apple or Cloudflare networking. */
export async function exportAvatarExpiryNativeFixture() {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  const snapshots = {};
  const capture = async (name, action, changes = {}) => {
    const response = await f.call(action, changes), body = await response.json();
    assert.equal(response.status, 200, JSON.stringify(body)); snapshots[name] = body; return body;
  };
  try {
    const initial = await capture("pending", "upload"), transfers = f.transfers.length;
    assert.equal(initial.status, "pending-review"); assert.equal(transfers, 4);
    f.advance(7 * 86400000); await f.relogin(); f.env.GATEWAY_EXPIRES_AT = new Date(f.clock() + 6 * 86400000).toISOString();
    assert.equal((await capture("expired", "status")).status, "expired");
    assert.equal((await capture("recovered", "recover", { requestID: initial.requestID })).status, "expired");
    await f.registry.backfillRetention(); f.advance(86400000); await f.relogin();
    f.env.GATEWAY_EXPIRES_AT = new Date(f.clock() + 6 * 86400000).toISOString();
    const processor = new CloudKitPublicRetentionProcessor({ registry: f.registry, client: f.client, checkpoint: f.checkpoint, clock: f.clock, isEnabled: () => true });
    assert.equal((await processor.step()).processed, 1); await tick();
    assert.equal((await capture("expiredAfterFence", "status")).status, "expired");
    assert.equal((await capture("cleared", "clear")).status, "none");
    assert.equal(f.transfers.length, transfers);
    return { schemaVersion: 1, synthetic: true, source: "local Runtime/HTTP/SQLite/Wasm; modeled provider and accounts", snapshots,
      uploadTransfers: transfers, additionalTransfersAfterExpiry: 0 };
  } finally { f.close(); }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error("Provide the local fixture output path.");
  await writeFile(process.argv[2], JSON.stringify(await exportAvatarExpiryNativeFixture(), null, 2) + "\n");
}
