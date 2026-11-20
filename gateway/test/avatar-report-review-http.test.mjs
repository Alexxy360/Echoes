import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { avatarReportReviewHTTPFixture as setup } from "./support/avatar-report-review-http-fixture.mjs";
import { avatarReportReviewDeadline, avatarReportReviewAdmission, avatarReportReviewEdgeResponse, avatarReportReviewInspectionType, encodeAvatarReportReviewInspection, decodeAvatarReportReviewInspection } from "../src/avatar-report-review-http.mjs";
import { digest } from "../src/public-record-schema.mjs";
import { activeGatewayConfiguration } from "../src/gateway-runtime.mjs";
const fail = error => error?.code === "AVATAR_REPORT_REVIEW_RESPONSE";
const decision = () => ({ decisionID: randomUUID(), verdict: "hide_photo" });
async function decode(response, f) {
  assert.equal(response.status, 200); assert.equal(response.headers.get("Content-Type"), avatarReportReviewInspectionType);
  const bytes = new Uint8Array(await response.arrayBuffer());
  try { const result = decodeAvatarReportReviewInspection(bytes, { reportID: f.report.context.recordName }, f.clock()); if (result.image) result.image.fill(0); return result.metadata; }
  finally { bytes.fill(0); }
}

test("photo-report moderation binary frame binds exact reason and JPEG while consuming the coordinator copy", async t => {
  const f = await setup(t), material = await f.inspection(), expected = material.image.slice(), request = { reportID: f.report.context.recordName };
  const response = encodeAvatarReportReviewInspection(material, request, f.clock()); assert.ok(material.image.every(x => x === 0));
  const bytes = new Uint8Array(await response.arrayBuffer()), parsed = decodeAvatarReportReviewInspection(bytes, request, f.clock());
  assert.equal(parsed.metadata.reason, f.report.input.reason); assert.equal(digest(parsed.image), digest(expected)); parsed.image.fill(0); bytes.fill(0); expected.fill(0);
});

test("photo-report frame rejects truncation, metadata overrun, protocol mismatch, extra keys, invalid UTF8 and trailing image bytes", async t => {
  const f = await setup(t), material = await f.inspection(), response = encodeAvatarReportReviewInspection(material, null, f.clock()), valid = new Uint8Array(await response.arrayBuffer());
  const length = new DataView(valid.buffer).getUint32(0), original = JSON.parse(new TextDecoder().decode(valid.subarray(4, 4 + length))), image = valid.slice(4 + length);
  const frame = raw => { const metadata = typeof raw === "string" ? new TextEncoder().encode(raw) : raw, result = new Uint8Array(4 + metadata.length + image.length); new DataView(result.buffer).setUint32(0, metadata.length); result.set(metadata, 4); result.set(image, 4 + metadata.length); return result; };
  const cases = [valid.slice(0, 3), valid.slice(0, -1), frame(JSON.stringify({ ...original, protocolVersion: 2 })), frame(JSON.stringify({ ...original, url: "PRIVATE" })), frame(new Uint8Array([255]))];
  const overrun = valid.slice(); new DataView(overrun.buffer).setUint32(0, 12289); cases.push(overrun);
  const extra = new Uint8Array(valid.length + 1); extra.set(valid); cases.push(extra);
  for (const value of cases) { assert.throws(() => decodeAvatarReportReviewInspection(value, null, f.clock()), fail); value.fill(0); }
  valid.fill(0); image.fill(0);
});

test("a dismiss-only frame has no pixels and cannot smuggle a newer image or a mismatched manifest", async t => {
  const f = await setup(t); await f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: f.publication.generation });
  const material = await f.inspection(), response = encodeAvatarReportReviewInspection(material, null, f.clock()), bytes = new Uint8Array(await response.arrayBuffer());
  assert.equal(decodeAvatarReportReviewInspection(bytes, null, f.clock()).image, null);
  const smuggled = new Uint8Array(bytes.length + 1); smuggled.set(bytes); assert.throws(() => decodeAvatarReportReviewInspection(smuggled, null, f.clock()), fail);
  assert.throws(() => encodeAvatarReportReviewInspection({ metadata: material.metadata, image: new Uint8Array(1) }, null, f.clock()), fail); bytes.fill(0); smuggled.fill(0);
});

test("photo-report HTTP rejects default flag, ordinary account and forged role before body or checkpoint", async t => {
  const f = await setup(t); f.setFeature(false); assert.equal((await f.call("inspect")).status, 503); f.setFeature(true);
  assert.equal((await f.call("inspect", {}, { token: f.viewer.sessionToken })).status, 403);
  assert.equal((await f.call("inspect", { operator: true })).status, 400);
  assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
});

test("photo-report authority emits a private bounded inspection frame and exact JSON decision/recovery", async t => {
  const f = await setup(t), metadata = await decode(await f.call("inspect"), f), input = { inspectionID: metadata.inspectionID, ...decision() };
  const response = await f.call("decide", input), body = await response.json(); assert.equal(response.status, 200); assert.equal(body.verdict, "hide_photo");
  const recovery = await f.call("recover", { reportID: metadata.reportID, decisionID: input.decisionID, verdict: input.verdict, contentHash: metadata.contentHash });
  assert.equal((await recovery.json()).outcome, "confirmed"); assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected");
});

test("actual Runtime edge and private authority carry the full photo-report frame with upload/read/message-review disabled", async t => {
  const f = await setup(t, { runtime: true }); assert.equal(f.env.AVATAR_READ_ENABLED, undefined);
  const queue = await f.edge("queue"); assert.equal(queue.status, 200); assert.equal((await queue.json()).items.length, 1);
  const metadata = await decode(await f.edge("inspect"), f), input = { inspectionID: metadata.inspectionID, ...decision() };
  const result = await f.edge("decide", input); assert.equal(result.status, 200); assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected");
  const recovered = await f.edge("recover", { reportID: metadata.reportID, decisionID: input.decisionID, verdict: input.verdict, contentHash: metadata.contentHash });
  assert.equal((await recovered.json()).outcome, "confirmed"); assert.equal(f.downloads.length, 1);
  assert.ok(f.forwarded.every(req => new URL(req.url).hostname === "echoes-authority.internal"));
});

test("photo-report edge rejects malformed binary success, wrong lengths/content-type/cache and foreign input bindings", async t => {
  const f = await setup(t), material = await f.inspection(), valid = new Uint8Array(await encodeAvatarReportReviewInspection(material, null, f.clock()).arrayBuffer());
  for (const patch of [{ "Content-Type": "image/jpeg" }, { "Cache-Control": "no-store" }, { "Content-Length": String(valid.length + 1) }, { "Content-Encoding": "gzip" }, { "Content-Range": "bytes 0-1/2" }]) {
    const claim = avatarReportReviewAdmission()(), deadline = avatarReportReviewDeadline();
    try { await assert.rejects(avatarReportReviewEdgeResponse(new Response(valid.slice(), { headers: { "Content-Type": avatarReportReviewInspectionType, "Content-Length": String(valid.length), "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff", ...patch } }), "inspect", { reportID: f.report.context.recordName }, deadline, claim, f.clock), fail); }
    finally { deadline.close(); claim.close(); }
  }
  assert.throws(() => decodeAvatarReportReviewInspection(valid, { reportID: "community-v1-avatarreport-" + "a".repeat(64) }, f.clock()), fail); valid.fill(0);
});

test("invalid flags, empty or async client role inputs never activate photo-report Runtime configuration", async t => {
  const f = await setup(t);
  assert.ok(activeGatewayConfiguration(f.env, f.clock()));
  for (const patch of [{ AVATAR_REPORT_REVIEW_ENABLED: "yes" }, { AVATAR_REPORT_REVIEWER_IDS_JSON: "[]" }, { COMMUNITY_ENABLED: "0" }, { AVATAR_DOWNLOAD_HOSTS_JSON: "[]" }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...patch }, f.clock()), null);
  f.env.AVATAR_REPORT_REVIEW_ENABLED = "0"; assert.equal((await f.edge("queue")).status, 503);
});

test("photo-report reviewer quota runs before malformed body parsing and checkpoint/provider work", async t => {
  const f = await setup(t);
  for (let i = 0; i < 10; i++) assert.equal((await f.call("inspect", {}, { rawBody: "{" })).status, 400);
  const response = await f.call("inspect", {}, { rawBody: "{" }); assert.equal(response.status, 429); assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
});

test("revoking photo-report role after preparation suppresses both binary frame and a durable decision ACK", async t => {
  const f = await setup(t); f.afterLastAdvance(() => f.role(false));
  assert.equal((await f.call("inspect")).status, 403); f.role(true); f.afterLastAdvance(undefined);
  const metadata = await decode(await f.call("inspect"), f), input = { inspectionID: metadata.inspectionID, ...decision() };
  f.afterLastAdvance(() => f.role(false)); assert.equal((await f.call("decide", input)).status, 403);
  f.role(true); f.afterLastAdvance(undefined);
  assert.equal((await (await f.call("recover", { reportID: metadata.reportID, decisionID: input.decisionID, verdict: input.verdict, contentHash: metadata.contentHash })).json()).outcome, "confirmed");
});

test("photo-report encoder rejects changed identity/hash or noncanonical reason and clears rejected image copies", async t => {
  const f = await setup(t), material = await f.inspection();
  for (const mutate of [m => { m.photo.versionID = randomUUID(); }, m => { m.photo.manifest.sha256 = "a".repeat(64); }, m => { m.photo.manifest.byteCount += 1; }, m => { m.reason = "  reason  "; }, m => { m.reason = "\ud800"; }]) {
    const metadata = structuredClone(material.metadata), image = material.image.slice(); mutate(metadata);
    assert.throws(() => encodeAvatarReportReviewInspection({ metadata, image }, null, f.clock()), fail); assert.ok(image.every(x => x === 0));
  }
});

test("photo-report malformed body chunk budget is enforced before checkpoint and reader cancellation completes", async t => {
  const f = await setup(t); let cancelled = false;
  const stream = new ReadableStream({ start(controller) { for (let i = 0; i < 129; i++) controller.enqueue(new Uint8Array([32])); }, cancel() { cancelled = true; } });
  const response = await f.call("inspect", {}, { rawBody: stream }); assert.equal(response.status, 400); assert.equal(cancelled, true);
  assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
});

test("an incomplete photo-report frame never exposes metadata and retained edge admission waits for real stream cancel", async t => {
  const f = await setup(t), material = await f.inspection(), bytes = new Uint8Array(await encodeAvatarReportReviewInspection(material, null, f.clock()).arrayBuffer());
  let entered, release; const started = new Promise(r => { entered = r; }), draining = new Promise(r => { release = r; });
  const controller = new AbortController(), gate = avatarReportReviewAdmission(), admission = gate(), deadline = avatarReportReviewDeadline(controller.signal);
  const stream = new ReadableStream({ start(c) { c.enqueue(bytes.slice(0, 12)); }, pull() { entered(); }, cancel() { return draining; } });
  const response = new Response(stream, { headers: { "Content-Type": avatarReportReviewInspectionType, "Content-Length": String(bytes.length), "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
  const actual = admission.run(deadline, () => avatarReportReviewEdgeResponse(response, "inspect", { reportID: f.report.context.recordName }, deadline, admission, f.clock)).catch(e => e);
  await started; controller.abort(); const error = await actual; assert.ok(["AVATAR_REPORT_REVIEW_UNAVAILABLE", "AVATAR_REPORT_REVIEW_RESPONSE"].includes(error.code));
  admission.close(); assert.throws(() => gate(), e => e.code === "AVATAR_REPORT_REVIEW_CAPACITY");
  release(); await new Promise(r => setImmediate(r)); await new Promise(r => setImmediate(r)); const next = gate(); next.close(); deadline.close(); bytes.fill(0);
});


test("photo-report HTTP deadlines reject a partial wall rollback after a forward observation", t => {
  let now = Date.now(); t.mock.method(Date, "now", () => now); const deadline = avatarReportReviewDeadline();
  try { now += 100; deadline.check(); now -= 1; assert.throws(() => deadline.check(), e => e.code === "AVATAR_REPORT_REVIEW_UNAVAILABLE"); }
  finally { deadline.close(); }
});
