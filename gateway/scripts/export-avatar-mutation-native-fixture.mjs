// Actual local Runtime/HTTP/SQLite/publication -> native wire contract. Synthetic identities,
// modeled Apple and unregistered ephemeral keys only; no service activation or real user content.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { avatarUploadHTTPFixture } from "../test/support/avatar-upload-http-fixture.mjs";

const f = await avatarUploadHTTPFixture({ runtime: true, readEnabled: true });
try {
  const cases = [];
  async function run(label, action, input = f.body(action), expectedStatus = 200) {
    const response = await f.edge(action, input), body = await response.json();
    assert.equal(response.status, expectedStatus, JSON.stringify(body));
    cases.push({ label, action, input, status: response.status, headers: Object.fromEntries(response.headers), body });
    return body;
  }
  await run("status-empty", "status");
  const intent = f.body("upload"), staged = await run("upload-pending", "upload", intent);
  const waiting = await run("publish-pending", "publish", { requestID: intent.requestID }, 409);
  assert.equal(waiting.error, "AVATAR_PENDING");
  await run("recover-pending", "recover", { requestID: intent.requestID });
  const review = await f.coordinator.prepareReview(f.review(staged)); await f.checkpoint.advance(); review();
  await run("status-approved", "status");
  await run("publish-published", "publish", { requestID: intent.requestID });
  f.env.AVATAR_UPLOAD_ENABLED = "0";
  await run("clear-upload-disabled", "clear", { requestID: randomUUID(), expectedGeneration: 1 });
  await run("status-cleared", "status");
  await run("upload-disabled", "upload", f.body("upload"), 503);
  await run("clear-stale", "clear", { requestID: randomUUID(), expectedGeneration: 0 }, 409);
  assert.equal(f.transfers.filter(c => c.phase === "upload").length, 2);
  const payload = JSON.stringify({ schemaVersion: 1,
    source: "Concrete local Runtime/HTTP/SQLite/policy/Wasm and modeled Apple/accounts/platform; no real service IO",
    imageSHA256: createHash("sha256").update(f.sourceBytes).digest("hex"), cases }, null, 2) + "\n";
  for (const text of [f.signedIn.sessionToken, "SYNTHETIC-PRIVATE", "PRIVATE KEY", "receipt", "downloadURL", "uploadURL"]) assert.equal(payload.includes(text), false);
  const directory = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-mutation/", import.meta.url);
  await mkdir(directory, { recursive: true });
  await writeFile(new URL("responses.json", directory), payload);
  await writeFile(new URL("source.jpg", directory), f.sourceBytes);
  process.stdout.write(JSON.stringify({ cases: cases.length, sourceBytes: f.sourceBytes.length, uploadVariants: 2, recoveryRetransmissions: 0, provider: "model only" }) + "\n");
} finally { f.close(); }
