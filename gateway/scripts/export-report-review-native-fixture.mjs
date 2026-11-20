// Concrete offline edge/Authority/Runtime/SQLite -> Swift contract. All identities,
// signing keys and CloudKit provider responses are synthetic; no external fetch.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { reportHTTPFixture } from "../test/support/report-review-http-fixture.mjs";

const cleanup = [], cases = [];
try {
  const f = await reportHTTPFixture({ after(fn) { cleanup.push(fn); } }, { runtime: true });
  const nowMilliseconds = f.clock();
  async function run(label, action, input = {}, status = 200, options = {}) {
    const response = await f.edge(action, input, options), body = await response.json();
    assert.equal(response.status, status, JSON.stringify(body));
    cases.push({ label, action, input: f.body(action, input), status, headers: Object.fromEntries(response.headers), body });
    return body;
  }
  const queue = await run("queue-open", "queue"); assert.equal(queue.items.length, 1);
  const inspection = await run("inspect-message", "inspect"); assert.equal(inspection.message.text, "PRIVATE-SYNTHETIC-MESSAGE");
  const retiring = { reportID: inspection.reportID, decisionID: randomUUID(), verdict: "hide_message", contentHash: inspection.contentHash };
  assert.equal((await run("retire-pending", "retire", retiring)).outcome, "retired");
  assert.equal((await run("recover-retired", "recover", retiring)).outcome, "retired");
  await run("late-retired-decision", "decide", { inspectionID: inspection.inspectionID, decisionID: retiring.decisionID, verdict: retiring.verdict }, 409);
  const decision = { inspectionID: inspection.inspectionID, decisionID: randomUUID(), verdict: "hide_message" };
  const recovery = { reportID: inspection.reportID, decisionID: decision.decisionID, verdict: decision.verdict, contentHash: inspection.contentHash };
  assert.equal((await run("recover-not-applied", "recover", recovery)).outcome, "not-applied");
  const result = await run("decide-hidden", "decide", decision);
  assert.deepEqual(await run("decide-replay", "decide", decision), result);
  assert.equal((await run("recover-confirmed", "recover", recovery)).revision, result.revision);
  assert.equal((await run("retire-already-confirmed", "retire", recovery)).revision, result.revision);
  assert.equal((await run("recover-superseded", "recover", { ...recovery, decisionID: randomUUID() })).outcome, "superseded");
  assert.deepEqual((await run("queue-closed", "queue")).items, []);
  f.advance(60_000); // Keep the expanded capture within real edge network limits.
  await run("queue-ordinary-denied", "queue", {}, 403, { token: f.reporter.sessionToken });
  f.env.REPORT_REVIEW_ENABLED = "0"; await run("queue-disabled", "queue", {}, 503);
  const payload = JSON.stringify({ schemaVersion: 1, source: "Concrete offline edge/Authority/Runtime/SQLite; synthetic provider and identities", nowMilliseconds, cases }, null, 2) + "\n";
  for (const forbidden of [f.operator.sessionToken, f.reporter.sessionToken, f.author.sessionToken, "PRIVATE KEY", "reporterID", "latitude", "longitude"]) assert.equal(payload.includes(forbidden), false);
  const directory = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/report-review/", import.meta.url);
  await mkdir(directory, { recursive: true }); await writeFile(new URL("responses.json", directory), payload);
  process.stdout.write(JSON.stringify({ cases: cases.length, source: "local Runtime/SQLite", provider: "synthetic", externalNetwork: false }) + "\n");
} finally { for (const close of cleanup.reverse()) await close(); }
