// Concrete local edge/Authority/Runtime/SQLite wire; modeled Apple/accounts/files/IP.
// No external network, real keys or user data. Frames are kept byte-for-byte for Swift.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { avatarReportReviewHTTPFixture } from "../test/support/avatar-report-review-http-fixture.mjs";
import { decodeAvatarReportReviewInspection } from "../src/avatar-report-review-http.mjs";
const cleanup = [], cases = [], files = [];
try {
  const t = { after(fn) { cleanup.push(fn); } }, f = await avatarReportReviewHTTPFixture(t, { runtime: true });
  const nowMilliseconds = f.clock();
  async function run(label, action, input = {}, status = 200, options = {}) {
    const response = await f.edge(action, input, options); assert.equal(response.status, status);
    const row = { label, action, input: f.body(action, input), status, headers: Object.fromEntries(response.headers) };
    if (action === "inspect" && status === 200) {
      const bytes = new Uint8Array(await response.arrayBuffer()), parsed = decodeAvatarReportReviewInspection(bytes, input.reportID ? input : null, f.clock());
      row.frame = label + ".bin"; files.push([row.frame, bytes]); cases.push(row); parsed.image?.fill(0); return parsed.metadata;
    }
    row.body = await response.json(); cases.push(row); return row.body;
  }
  assert.equal((await run("queue-open", "queue")).items.length, 1);
  const inspection = await run("inspect-photo", "inspect"); assert.ok(inspection.photo);
  const retiring = { reportID: inspection.reportID, decisionID: randomUUID(), verdict: "hide_photo", contentHash: inspection.contentHash };
  assert.equal((await run("retire-pending", "retire", retiring)).outcome, "retired");
  assert.equal((await run("recover-retired", "recover", retiring)).outcome, "retired");
  await run("late-retired-decision", "decide", { inspectionID: inspection.inspectionID, decisionID: retiring.decisionID, verdict: retiring.verdict }, 409);
  const decision = { inspectionID: inspection.inspectionID, decisionID: randomUUID(), verdict: "hide_photo" };
  const recovery = { reportID: inspection.reportID, decisionID: decision.decisionID, verdict: decision.verdict, contentHash: inspection.contentHash };
  assert.equal((await run("recover-not-applied", "recover", recovery)).outcome, "not-applied");
  const result = await run("decide-hidden", "decide", decision);
  assert.deepEqual(await run("decide-replay", "decide", decision), result);
  assert.equal((await run("recover-confirmed", "recover", recovery)).revision, result.revision);
  assert.equal((await run("retire-already-confirmed", "retire", recovery)).revision, result.revision);
  assert.equal((await run("recover-superseded", "recover", { ...recovery, decisionID: randomUUID() })).outcome, "superseded");
  assert.deepEqual((await run("queue-closed", "queue")).items, []);
  f.advance(60_000);
  await run("queue-ordinary-denied", "queue", {}, 403, { token: f.viewer.sessionToken });
  f.env.AVATAR_REPORT_REVIEW_ENABLED = "0"; await run("queue-disabled", "queue", {}, 503);
  // A distinct synthetic Runtime models an original photo withdrawn before inspection.
  const missing = await avatarReportReviewHTTPFixture(t, { runtime: true });
  await missing.policy.clear({ accountID: missing.signedIn.accountID, requestID: randomUUID(), expectedGeneration: missing.publication.generation });
  const response = await missing.edge("inspect"), bytes = new Uint8Array(await response.arrayBuffer());assert.equal(response.status, 200);
  assert.equal(decodeAvatarReportReviewInspection(bytes, null, missing.clock()).metadata.photo, null);
  cases.push({ label: "inspect-missing", action: "inspect", input: missing.body("inspect"), status: 200, headers: Object.fromEntries(response.headers), frame: "inspect-missing.bin" });files.push(["inspect-missing.bin", bytes]);
  const payload = JSON.stringify({ schemaVersion: 1, source: "Concrete local edge/Authority/Runtime/SQLite; modeled Apple/accounts/files/IP", nowMilliseconds, cases }, null, 2) + "\n";
  for (const forbidden of [f.operator.sessionToken, f.viewer.sessionToken, f.signedIn.sessionToken, "PRIVATE KEY", "reporterID", "latitude", "longitude", "downloadURL"]) assert.equal(payload.includes(forbidden), false);
  const directory = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-report-review/", import.meta.url);await mkdir(directory, { recursive: true });
  for (const [name, bytes] of files) await writeFile(new URL(name, directory), bytes);
  await writeFile(new URL("responses.json", directory), payload);
  process.stdout.write(JSON.stringify({ cases: cases.length, frames: files.length, source: "concrete local Runtime/SQLite", provider: "modeled", externalNetwork: false }) + "\n");
} finally { for (const close of cleanup.reverse()) await close();for (const [, bytes] of files) bytes.fill(0); }
