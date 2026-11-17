// Read-only recovery wire from concrete local edge/Authority/Runtime/SQLite/policy.
// Apple, provider files, identities and platform bindings remain synthetic models.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { avatarReviewHTTPFixture } from "../test/support/avatar-review-http-fixture.mjs";
import { purgeAvatarReviewReceipts } from "../src/avatar-review-state.mjs";

const f = await avatarReviewHTTPFixture({ runtime: true });
try {
  const cases = [], queued = await (await f.edge("queue")).json(); assert.equal(queued.items.length, 1);
  const intent = { ...queued.items[0], decisionID: randomUUID(), verdict: "approved" };
  async function run(label, input = intent, outcome) {
    const response = await f.edge("recover", input), body = await response.json();
    assert.equal(response.status, 200, JSON.stringify(body)); assert.equal(body.outcome, outcome);
    cases.push({ label, input, status: response.status, headers: Object.fromEntries(response.headers), body });
    return body;
  }
  await run("not-applied", intent, "not-applied");
  const image = await f.edge("inspect", { accountID: intent.accountID, requestID: intent.requestID }); assert.equal(image.status, 200);
  const proof = f.reviewMetadata(image); await image.arrayBuffer();
  const decision = await f.edge("decide", { inspectionID: proof.inspectionID, decisionID: intent.decisionID, verdict: intent.verdict });
  assert.equal(decision.status, 200); const result = await decision.json();
  f.advance(90_000); await purgeAvatarReviewReceipts(f.storage, f.clock);
  assert.equal((await run("confirmed-after-expiry", intent, "confirmed")).revision, result.revision);
  await run("different-decision", { ...intent, decisionID: randomUUID() }, "superseded");
  const other = { ...intent, verdict: "rejected" };
  await run("different-verdict", other, "superseded");
  await f.policy.clear({ accountID: intent.accountID, requestID: randomUUID(), expectedGeneration: intent.generation });
  await f.checkpoint.advance(); await run("withdrawn", intent, "superseded");
  assert.equal(f.downloads.length, 1); assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
  const data = JSON.stringify({ schemaVersion: 1, source: "Concrete local edge/Authority/Runtime/SQLite/policy; modeled Apple/accounts/files/platform only", intent, cases }, null, 2) + "\n";
  for (const forbidden of [f.reviewer.sessionToken, f.signedIn.sessionToken, "SYNTHETIC-PRIVATE", "PRIVATE KEY", "downloadURL", "uploadURL"]) assert.equal(data.includes(forbidden), false);
  const dir = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-review-recovery/", import.meta.url);
  await mkdir(dir, { recursive: true }); await writeFile(new URL("responses.json", dir), data);
  process.stdout.write(JSON.stringify({ cases: cases.length, receiptRowsAfterExpiry: 0, recoveryAssetDownloads: 0, provider: "model only" }) + "\n");
} finally { f.close(); }
