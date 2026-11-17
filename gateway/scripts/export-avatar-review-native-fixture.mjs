// Concrete edge/Authority/Runtime/SQLite/Wasm responses for the native contract. Apple/accounts,
// platform bindings and provider files are synthetic models; no real service IO or activation.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { avatarReviewHTTPFixture } from "../test/support/avatar-review-http-fixture.mjs";

const f = await avatarReviewHTTPFixture({ runtime: true });
try {
  const cases = [], nowMilliseconds = f.clock();
  async function json(label, action, input = {}, expected = 200, options = {}) {
    const response = await f.edge(action, input, options), body = await response.json();
    assert.equal(response.status, expected, JSON.stringify(body));
    cases.push({ label, action, input, status: response.status, headers: Object.fromEntries(response.headers), body });
    return body;
  }
  const queue = await json("queue-pending", "queue"); assert.equal(queue.items.length, 1);
  const selection = queue.items[0], inspectInput = { accountID: selection.accountID, requestID: selection.requestID };
  const response = await f.edge("inspect", inspectInput); assert.equal(response.status, 200);
  const image = new Uint8Array(await response.arrayBuffer());
  cases.push({ label: "inspect-pending", action: "inspect", input: inspectInput, status: response.status, headers: Object.fromEntries(response.headers), image: "image.jpg" });
  const proof = JSON.parse(response.headers.get("x-echoes-avatar-review"));
  const decision = { inspectionID: proof.inspectionID, decisionID: randomUUID(), verdict: "approved" };
  const result = await json("decide-approved", "decide", decision);
  assert.deepEqual(await json("decide-exact-replay", "decide", decision), result);
  assert.equal(f.policy.snapshot(selection.accountID).publishedVersionID, null);
  assert.equal((await json("queue-reviewed", "queue")).items.length, 0);
  await json("queue-ordinary-denied", "queue", {}, 403, { token: f.signedIn.sessionToken });
  f.env.AVATAR_REVIEW_ENABLED = "0";
  await json("queue-disabled", "queue", {}, 503);
  const payload = JSON.stringify({ schemaVersion: 1,
    source: "Concrete local edge/Authority/Runtime/SQLite/policy/Wasm; modeled Apple/accounts/platform/files only",
    nowMilliseconds, imageSHA256: createHash("sha256").update(image).digest("hex"), selection, cases }, null, 2) + "\n";
  for (const forbidden of [f.reviewer.sessionToken, f.signedIn.sessionToken, "SYNTHETIC-PRIVATE", "PRIVATE KEY", "downloadURL", "uploadURL"])
    assert.equal(payload.includes(forbidden), false);
  const directory = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-review/", import.meta.url);
  await mkdir(directory, { recursive: true });
  await writeFile(new URL("responses.json", directory), payload);
  await writeFile(new URL("image.jpg", directory), image);
  process.stdout.write(JSON.stringify({ cases: cases.length, bytes: image.length, published: false, provider: "model only" }) + "\n");
} finally { f.close(); }
