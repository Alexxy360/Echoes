import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { digest } from "../src/public-record-schema.mjs";
import { AvatarReportReviewCoordinator } from "../src/avatar-report-review-coordinator.mjs";
import { avatarReportReviewFixture as setup } from "./support/avatar-report-review-fixture.mjs";
const code = expected => error => error?.code === "AVATAR_REPORT_REVIEW_" + expected && !error.message.includes("PRIVATE") && error.cause === undefined;
const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };

test("photo-report coordinator defaults closed and rejects ordinary or asynchronous operator roles before IO", async t => {
  const f = await setup(t), before = f.model.checkpointRequests.length;
  for (const patch of [{ isEnabled: undefined }, { isOperator: undefined }, { isOperator: async () => true }]) {
    const review = new AvatarReportReviewCoordinator({ ...f.reviewConfiguration, ...patch });
    await assert.rejects(review.prepareQueue(f.options()), e => ["AVATAR_REPORT_REVIEW_UNAVAILABLE", "AVATAR_REPORT_REVIEW_SCOPE"].includes(e.code));
  }
  await assert.rejects(f.review.prepareQueue(f.options({ accessToken: f.viewer.sessionToken })), code("SCOPE"));
  assert.equal(f.model.checkpointRequests.length, before); assert.equal(f.downloads.length, 0);
});

test("photo-report coordinator rejects cross-domain IDs, extra authorities and invalid input before provider access", async t => {
  const f = await setup(t), before = f.model.requests.length;
  for (const patch of [{ reportID: "community-v1-report-" + "a".repeat(64) }, { reportID: f.report.context.recordName, operator: true }, { reportID: f.report.context.recordName, ownerID: f.signedIn.accountID }]) await assert.rejects(f.review.prepareInspection(f.options(patch)), code("INPUT"));
  await assert.rejects(f.review.prepareQueue(f.options({ after: "bad" })), code("INPUT"));
  assert.equal(f.model.requests.length, before);
});

test("photo-report coordinator keyset pages filter closed reports without disclosing reasons or reporter identity", async t => {
  const f = await setup(t); for (let i = 1; i < 23; i++) await f.makeReport();
  const before = f.model.requests.length, seen = []; let after = null;
  do { const page = await f.queue({ after }); seen.push(...page.items.map(x => x.reportID)); after = page.after;
    assert.equal(JSON.stringify(page).includes(f.viewer.accountID), false); assert.equal(JSON.stringify(page).includes("PRIVATE"), false);
  } while (after);
  assert.equal(seen.length, 23); assert.equal(new Set(seen).size, 23); assert.equal(f.model.requests.length, before);
  const inspection = await f.inspection(); await f.decide(inspection, "dismiss");
  const remaining = []; after = null; do { const page = await f.queue({ after }); remaining.push(...page.items.map(x => x.reportID)); after = page.after; } while (after);
  assert.equal(remaining.length, 22); assert.ok(!remaining.includes(f.report.context.recordName));
});

test("photo-report inspection returns exact protected full JPEG and confidential reason without raw provider or reporter fields", async t => {
  const f = await setup(t), result = await f.inspection(), m = result.metadata;
  assert.equal(m.reason, f.report.input.reason); assert.equal(m.reportID, f.report.context.recordName);
  assert.equal(m.photo.versionID, f.publication.versionID); assert.equal(m.photo.publicationGeneration, f.publication.generation);
  assert.equal(digest(result.image), f.publication.descriptor.image.sha256); assert.equal(result.image.length, m.photo.manifest.byteCount);
  assert.equal(f.downloads.length, 1); assert.equal(f.storage.sql.exec("SELECT verified FROM avatar_report_inspections_v1").toArray()[0].verified, 1);
  for (const forbidden of [f.viewer.accountID, "downloadURL", "fileChecksum", "coordinate", "accessToken"]) assert.equal(JSON.stringify(m).includes(forbidden), false);
});

test("a prepared image finalizer is one-use and scope revocation suppresses both reason and pixels", async t => {
  const f = await setup(t), first = await f.review.prepareInspection(f.options({ reportID: f.report.context.recordName }));
  f.role(false); assert.throws(first, code("SCOPE")); f.role(true);
  const final = await f.review.prepareInspection(f.options({ reportID: f.report.context.recordName })); const result = final(); result.image.fill(0);
  assert.throws(final, code("UNAVAILABLE"));
});

test("clear after report submission returns dismiss-only material and never substitutes another photo", async t => {
  const f = await setup(t); await f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: f.publication.generation });
  const inspection = await f.inspection(); assert.equal(inspection.image, null); assert.equal(inspection.metadata.photo, null); assert.equal(f.downloads.length, 0);
  await assert.rejects(f.decide(inspection), code("STALE")); await f.decide(inspection, "dismiss"); assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "clearing");
});

test("a missing provider record or exact CDN404/410 replaces an unverified receipt with a dismiss-only receipt", async t => {
  for (const missing of ["record", 404, 410]) {
    const f = await setup(t);
    if (missing === "record") f.model.records.delete(f.publication.avatar.recordName);
    else f.setDownloadHook(() => new Response("PRIVATE-NOT-AN-IMAGE", { status: missing }));
    const inspection = await f.inspection(); assert.equal(inspection.metadata.photo, null); assert.equal(inspection.image, null);
    await assert.rejects(f.decide(inspection), code("STALE")); await f.decide(inspection, "dismiss"); assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published");
    assert.equal(f.storage.sql.exec("SELECT count FROM avatar_report_review_budgets_v1").toArray()[0].count, 2);
  }
});

test("download corruption, redirects and invalid provider manifests never confirm a photo-report receipt", async t => {
  for (const kind of ["bytes", "redirect", "manifest"]) {
    const f = await setup(t);
    if (kind === "manifest") f.model.records.get(f.publication.avatar.recordName).fields.imageSha256.value = "a".repeat(64);
    else f.setDownloadHook(({ request }) => kind === "redirect" ? new Response(null, { status: 302, headers: { Location: "https://foreign.invalid" } }) : new Response(new Uint8Array(f.publication.descriptor.image.byteCount), { headers: { "Content-Type": "image/jpeg" } }));
    await assert.rejects(f.inspection(), code("RESPONSE"));
    assert.ok(f.storage.sql.exec("SELECT verified FROM avatar_report_inspections_v1").toArray().every(x => x.verified === 0));
  }
});

test("moderator role removal during protected download withholds all inspection content", async t => {
  const f = await setup(t); f.setDownloadHook(() => { f.role(false); });
  await assert.rejects(f.inspection(), code("SCOPE")); assert.equal(f.review.isOccupied, false);
});

test("photo replacement or cancellation during protected download invalidates the exact original receipt", async t => {
  for (const mode of ["clear", "cancel"]) {
    const f = await setup(t); f.setDownloadHook(async () => {
      if (mode === "clear") await f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: f.publication.generation });
      else { f.setReportsCancellable(true); await f.cancel(f.report.context.requestID); }
    });
    await assert.rejects(f.inspection(), code("STALE"));
  }
});

test("cancellation retains the sole operation until an ignored-abort download actually returns and drains", async t => {
  const f = await setup(t), entered = barrier(), release = barrier(), controller = new AbortController();
  f.setDownloadHook(async () => { entered.release(); await release.promise; });
  const running = f.inspection({ signal: controller.signal }).catch(e => e); await entered.promise; controller.abort();
  assert.equal((await running).code, "AVATAR_REPORT_REVIEW_UNAVAILABLE"); assert.equal(f.review.isOccupied, true);
  await assert.rejects(f.queue(), code("CAPACITY")); release.release(); await f.review.waitForPendingOperations();
  assert.equal(f.review.isOccupied, false); f.setDownloadHook(undefined); assert.equal((await f.queue()).items.length, 1);
});

test("download cancellation failure closes future photo-report admission rather than reusing an unsafe scope", async t => {
  const f = await setup(t); f.setDownloadHook(() => new Response(new ReadableStream({ cancel() { throw new Error("PRIVATE-CANCEL"); } }), { headers: { "Content-Type": "text/plain" } }));
  await assert.rejects(f.inspection(), e => ["AVATAR_REPORT_REVIEW_RESPONSE", "AVATAR_REPORT_REVIEW_UNAVAILABLE"].includes(e.code));
  await assert.rejects(f.review.waitForPendingOperations()); await assert.rejects(f.queue(), e => ["AVATAR_REPORT_REVIEW_CAPACITY", "AVATAR_REPORT_REVIEW_UNAVAILABLE"].includes(e.code));
});

test("wall and monotonic partial rollback or expired finalizer never declassifies prepared report metadata", async t => {
  for (const mode of ["wall", "mono", "expire"]) {
    const f = await setup(t);
    f.model.afterCheckpoint = () => { f.advance(100); f.moveMono(100); };
    const final = await f.review.prepareQueue(f.options()); f.model.afterCheckpoint = undefined;
    if (mode === "wall") f.advance(-1); else if (mode === "mono") f.moveMono(-1); else f.advance(8000);
    assert.throws(final, code("UNAVAILABLE"));
  }
});

test("same bearer resolving to another permitted moderator cannot inherit an old prepared inspection", async t => {
  const f = await setup(t), other = await f.session("other.moderator"); let switched = false;
  const review = new AvatarReportReviewCoordinator({ ...f.reviewConfiguration, authentication: { authorize: () => ({ accountID: switched ? other.accountID : f.operator.accountID }) }, isOperator: () => true });
  const final = await review.prepareInspection(f.options({ reportID: f.report.context.recordName })); switched = true; assert.throws(final, code("SCOPE"));
});

test("tampered confidential reason cannot pass the repository payload hash to a moderator", async t => {
  const f = await setup(t); f.model.records.get(f.report.context.recordName).fields.reason.value = "PRIVATE-TAMPER";
  await assert.rejects(f.inspection(), code("RESPONSE")); assert.equal(f.downloads.length, 0);
});

test("moderator decision atomically hides inspected photo, replays exact result and recovers after inspection expiry without another download", async t => {
  const f = await setup(t), inspection = await f.inspection(), { input, result } = await f.decide(inspection);
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected");
  assert.deepEqual((await f.review.prepareDecision(f.options(input)))(), result);
  f.advance(90001); const recovered = (await f.review.prepareRecovery(f.options(f.recoveryInput(inspection, input))))();
  assert.equal(recovered.outcome, "confirmed"); assert.equal(recovered.revision, result.revision); assert.equal(f.downloads.length, 1);
});

test("publication changed after inspection cannot be hidden or silently dismissed from the stale image", async t => {
  const f = await setup(t), inspection = await f.inspection();
  await f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: f.publication.generation });
  await assert.rejects(f.decide(inspection), code("STALE")); await assert.rejects(f.decide(inspection, "dismiss"), code("STALE"));
});

test("lost durable decision acknowledgement recovers the original result without another mutation", async t => {
  let failSync = false; const f = await setup(t, { sqlHook: sql => { if (sql.startsWith("INSERT INTO avatar_report_decisions_v1")) failSync = true; }, syncHook: async () => { if (failSync) { failSync = false; throw new Error("PRIVATE-LOST-ACK"); } } });
  const inspection = await f.inspection(), input = { inspectionID: inspection.metadata.inspectionID, decisionID: randomUUID(), verdict: "hide_photo" };
  await assert.rejects(f.review.prepareDecision(f.options(input)), code("UNAVAILABLE"));
  const revision = f.policy.snapshot(f.signedIn.accountID).reviewRevision;
  const result = (await f.review.prepareRecovery(f.options(f.recoveryInput(inspection, input))))();
  assert.equal(result.outcome, "confirmed"); assert.equal(result.revision, revision); assert.equal(f.downloads.length, 1);
});

test("role revocation after durable decision checkpoint suppresses ACK while read-only recovery preserves its history", async t => {
  const f = await setup(t), inspection = await f.inspection(), input = { inspectionID: inspection.metadata.inspectionID, decisionID: randomUUID(), verdict: "hide_photo" };
  f.model.afterCheckpoint = ({ operation }) => { if (operation === "modify") f.role(false); };
  await assert.rejects(f.review.prepareDecision(f.options(input)), code("SCOPE")); f.model.afterCheckpoint = undefined; f.role(true);
  assert.equal((await f.review.prepareRecovery(f.options(f.recoveryInput(inspection, input))))().outcome, "confirmed");
});

test("ten inspections consume the protected image budget and the eleventh fails before avatar or CDN fetch", async t => {
  const f = await setup(t); for (let i = 0; i < 10; i++) await f.inspection();
  const before = f.model.requests.length; await assert.rejects(f.inspection(), code("CAPACITY"));
  assert.equal(f.downloads.length, 10); const extra = f.model.requests.slice(before);
  assert.equal(extra.length, 1); assert.deepEqual(extra[0].body.records.map(x => x.recordName), [f.report.context.recordName]);
});

test("queue finalizer filters a cancellation reserved after its last checkpoint", async t => {
  const f = await setup(t), final = await f.review.prepareQueue(f.options()); f.setReportsCancellable(true);
  await f.cancel(f.report.context.requestID); assert.deepEqual(final().items, []);
});

test("first response-body cancellation must settle before the photo-report slot can be reused", async t => {
  const f = await setup(t), entered = barrier(), release = barrier(), controller = new AbortController();
  f.setDownloadHook(() => new Response(new ReadableStream({ cancel() { entered.release(); return release.promise; } }), { headers: { "Content-Type": "text/plain" } }));
  const running = f.inspection({ signal: controller.signal }).catch(e => e); await entered.promise; controller.abort();
  assert.equal((await running).code, "AVATAR_REPORT_REVIEW_UNAVAILABLE"); assert.equal(f.review.isOccupied, true);
  await assert.rejects(f.queue(), code("CAPACITY")); release.release(); await f.review.waitForPendingOperations();
  f.setDownloadHook(undefined); assert.equal((await f.queue()).items.length, 1);
});

test("an old consumed finalizer cannot release the slot of a newer unsettled photo-report inspection", async t => {
  const f = await setup(t), old = await f.review.prepareQueue(f.options()); old();
  const entered = barrier(), release = barrier(); f.setDownloadHook(async () => { entered.release(); await release.promise; });
  const running = f.inspection(); await entered.promise; assert.throws(old, code("UNAVAILABLE"));
  await assert.rejects(f.queue(), code("CAPACITY")); release.release(); const result = await running; assert.ok(result.image); assert.equal(f.review.isOccupied, false);
});
