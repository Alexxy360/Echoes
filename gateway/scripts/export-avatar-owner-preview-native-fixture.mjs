// Concrete local edge/Authority/Runtime/SQLite/policy responses. Apple/accounts/files/platform
// are models. No remote service access, activation or real account data.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { avatarOwnerPreviewFixture } from "../test/support/avatar-owner-preview-fixture.mjs";

const f = await avatarOwnerPreviewFixture({ runtime: true });
try {
  const cases = [], selection = { ownerID: f.signedIn.accountID, ...f.body() }, nowMilliseconds = f.clock();
  let image;
  async function record(label, input = {}, expected = 200, options = {}) {
    const response = await f.edge(input, options); assert.equal(response.status, expected);
    const row = { label, input: f.body(input), status: response.status, headers: Object.fromEntries(response.headers) };
    if (expected === 200) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (image) assert.deepEqual(bytes, image); else image = bytes;
      row.image = "image.jpg";
    } else row.body = await response.json();
    cases.push(row);
  }
  await record("approved-unpublished");
  await record("other-account-denied", {}, 404, { token: f.viewer.sessionToken });
  const done = await f.coordinator.prepareReview(f.review(f.current)); await f.checkpoint.advance(); done();
  await record("old-revision-denied", {}, 404);
  const { consentVersion, ...newSelection } = f.publication();
  await record("reapproved-unpublished", newSelection);
  const clear = await f.coordinator.prepareClear(f.credentials({ requestID: randomUUID(), expectedGeneration: f.current.generation }));
  await f.checkpoint.advance(); clear();
  await record("cleared-denied", newSelection, 404);
  await record("client-owner-denied", { ownerID: f.signedIn.accountID }, 400);
  await record("invalid-session", {}, 401, { token: "bad" });
  f.env.AVATAR_OWNER_PREVIEW_ENABLED = "0"; await record("feature-disabled", {}, 503);
  const payload = JSON.stringify({ schemaVersion: 1, source: "Concrete local edge/Authority/Runtime/SQLite/policy; modeled Apple/accounts/files/platform only",
    nowMilliseconds, selection, imageSHA256: createHash("sha256").update(image).digest("hex"), cases }, null, 2) + "\n";
  for (const forbidden of [f.signedIn.sessionToken, f.viewer.sessionToken, "SYNTHETIC-PRIVATE", "PRIVATE KEY", "downloadURL", "uploadURL"]) assert.equal(payload.includes(forbidden), false);
  const directory = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-owner-preview/", import.meta.url);
  await mkdir(directory, { recursive: true }); await writeFile(new URL("responses.json", directory), payload); await writeFile(new URL("image.jpg", directory), image);
  process.stdout.write(JSON.stringify({ cases: cases.length, bytes: image.length, provider: "model only", source: "concrete local edge/Authority/Runtime" }) + "\n");
} finally { f.close(); }
