import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { reportHTTPFixture } from "./support/report-review-http-fixture.mjs";
import { avatarReportReviewHTTPFixture } from "./support/avatar-report-review-http-fixture.mjs";
import { decodeAvatarReportReviewInspection } from "../src/avatar-report-review-http.mjs";
for (const photo of [false, true]) {
  const label = photo ? "photo" : "message";
  test(label + " retirement HTTP and real Runtime reject a delayed same decision and keep readonly recovery", async t => {
    const f = await (photo ? avatarReportReviewHTTPFixture(t, { runtime: true }) : reportHTTPFixture(t, { runtime: true }));
    const inspected = await f.edge("inspect"); assert.equal(inspected.status, 200);
    const material = photo ? decodeAvatarReportReviewInspection(new Uint8Array(await inspected.arrayBuffer()), null, f.clock()) : null;
    const metadata = photo ? material.metadata : await inspected.json(); material?.image?.fill(0);
    const q = { reportID: metadata.reportID, decisionID: randomUUID(), verdict: photo ? "hide_photo" : "hide_message", contentHash: metadata.contentHash };
    assert.equal((await (await f.edge("recover", q)).json()).outcome, "not-applied");
    const closed = await f.edge("retire", q); assert.equal(closed.status, 200); assert.equal((await closed.json()).outcome, "retired");
    const late = await f.edge("decide", { inspectionID: metadata.inspectionID, decisionID: q.decisionID, verdict: q.verdict }); assert.equal(late.status, 409);
    assert.equal((await (await f.edge("recover", q)).json()).outcome, "retired");
  });
  test(label + " retirement role and flag precede parsing, checkpoint or content IO", async t => {
    const f = await (photo ? avatarReportReviewHTTPFixture(t) : reportHTTPFixture(t)), q = { reportID: photo ? f.report.context.recordName : f.report.recordName, decisionID: randomUUID(), verdict: "dismiss", contentHash: "a".repeat(64) };
    f.setFeature(false); assert.equal((await f.call("retire", q)).status, 503); f.setFeature(true);
    const foreign = photo ? f.viewer : f.reporter; assert.equal((await f.call("retire", q, { token: foreign.sessionToken })).status, 403);
    assert.equal((await f.call("retire", { ...q, operator: true })).status, 400); assert.equal(f.counts().verifies, 0);
  });
  test(label + " retirement response validator never accepts a mere not-applied read as terminal", async t => {
    const f = await (photo ? avatarReportReviewHTTPFixture(t) : reportHTTPFixture(t)), q = { reportID: photo ? f.report.context.recordName : f.report.recordName, decisionID: randomUUID(), verdict: "dismiss", contentHash: "a".repeat(64) };
    const dependency = photo ? f.deps.avatarReportReview : f.deps.reportReview;
    dependency.prepareRetirement = async () => () => ({ schemaVersion: 1, ...q, outcome: "not-applied", revision: null });
    assert.equal((await f.call("retire", q)).status, 503);
  });
}
