import assert from "node:assert/strict";
import test from "node:test";
import { randomUUID } from "node:crypto";
import { avatarReviewFixture } from "./support/avatar-review-fixture.mjs";
import { AvatarReviewCoordinator } from "../src/avatar-review-coordinator.mjs";
import { AvatarReviewReceipts, AvatarReviewError, purgeAvatarReviewReceipts, avatarReviewerKey } from "../src/avatar-review-state.mjs";
import { digest } from "../src/public-record-schema.mjs";
const code = value => e => e instanceof AvatarReviewError && e.code === value && e.message === "Photo review could not be completed." && e.cause === undefined;
const decision = (f, response, changes = {}) => f.input({ inspectionID: f.reviewMetadata(response).inspectionID, decisionID: randomUUID(), verdict: "approved", ...changes });
function gate() { let open, arrived; const entered = new Promise(r => { arrived = r; }), waiting = new Promise(r => { open = r; }); return { entered, release: open, async wait() { arrived(); await waiting; } }; }

test("moderation queue contains only current staged pending metadata and no provider fields", async () => {
  const f = await avatarReviewFixture();
  try {
    const result = await f.reviewCall("prepareQueue", f.input());
    assert.deepEqual(result, { schemaVersion: 1, items: [{ accountID: f.signedIn.accountID, requestID: f.pending.requestID,
      versionID: f.pending.versionID, generation: f.pending.generation, reviewRevision: f.pending.reviewRevision }] });
    assert.equal(f.downloads.length, 0);
    const response = await f.inspect(); await f.reviewCall("prepareDecision", decision(f, response));
    assert.deepEqual((await f.reviewCall("prepareQueue", f.input())).items, []);
  } finally { f.close(); }
});

test("inspection validates actual full JPEG and emits a one-shot session-bound receipt without publishing", async () => {
  const f = await avatarReviewFixture();
  try {
    const finalize = await f.coordinator.prepareInspection(f.inspection());
    await f.checkpoint.advance(); const response = finalize();
    assert.equal(response.status, 200); assert.equal(response.headers.get("cache-control"), "private, no-store");
    const bytes = new Uint8Array(await response.arrayBuffer()), manifest = JSON.parse(response.headers.get("x-echoes-avatar-manifest")), receipt = f.reviewMetadata(response);
    assert.equal(manifest.variant, "image"); assert.equal(digest(bytes), manifest.sha256); assert.equal(bytes.length, manifest.byteCount);
    assert.equal(receipt.requestID, f.pending.requestID); assert.equal(receipt.reviewRevision, f.pending.reviewRevision);
    assert.equal(receipt.expiresAt, f.clock() + 90000);
    assert.throws(finalize, code("AVATAR_REVIEW_UNAVAILABLE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "pending-review");
    assert.doesNotMatch(JSON.stringify(receipt), /downloadURL|SYNTHETIC-PRIVATE|sessionToken|fileChecksum/);
    const row = f.db.prepare("SELECT * FROM avatar_review_receipts_v1").get();
    assert.notEqual(row.inspection_key, receipt.inspectionID); assert.notEqual(row.session_key, f.reviewer.sessionToken);
    assert.doesNotMatch(JSON.stringify(row), /downloadURL|SYNTHETIC-PRIVATE|image\/jpeg/);
  } finally { f.close(); }
});

test("a decision requires inspection and exact retry is idempotent after lost final response", async () => {
  const f = await avatarReviewFixture();
  try {
    await assert.rejects(() => f.reviewCall("prepareDecision", f.input({ inspectionID: randomUUID(), decisionID: randomUUID(), verdict: "approved" })), code("AVATAR_REVIEW_STALE"));
    const response = await f.inspect(), input = decision(f, response);
    const finalize = await f.coordinator.prepareDecision(input); // Simulate response never delivered; still release old finalizer.
    f.cancel(input);
    assert.throws(finalize, code("AVATAR_REVIEW_UNAVAILABLE"));
    const result = await f.reviewCall("prepareDecision", { ...input, signal: undefined });
    assert.equal(result.verdict, "approved"); assert.equal(result.decisionID, input.decisionID);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "approved");
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    assert.deepEqual(await f.reviewCall("prepareDecision", { ...input, signal: undefined }), result);
    for (const change of [{ verdict: "rejected" }, { decisionID: randomUUID() }])
      await assert.rejects(() => f.reviewCall("prepareDecision", { ...input, signal: undefined, ...change }), code("AVATAR_REVIEW_STALE"));
  } finally { f.close(); }
});

test("normal sessions, missing role and async identity or role checks cannot inspect", async () => {
  const f = await avatarReviewFixture();
  try {
    for (const operator of [() => false, () => undefined, () => Promise.resolve(true)]) {
      await assert.rejects(() => f.reviewCall("prepareInspection", f.inspection(), f.makeReview({ isOperator: operator })), code("AVATAR_REVIEW_SCOPE"));
    }
    await assert.rejects(() => f.inspect({ accessToken: f.signedIn.sessionToken }), code("AVATAR_REVIEW_SCOPE"));
    await assert.rejects(() => f.reviewCall("prepareQueue", f.input(), f.makeReview({ authentication: { authorize: async () => ({ accountID: f.reviewer.accountID }) } })), code("AVATAR_REVIEW_SCOPE"));
    assert.equal(f.downloads.length, 0);
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1 WHERE verified=1").get().n, 0);
  } finally { f.close(); }
});

test("inspection finalizer rechecks operator authorization after the final checkpoint", async () => {
  const f = await avatarReviewFixture();
  try {
    const finalize = await f.coordinator.prepareInspection(f.inspection()); await f.checkpoint.advance();
    f.operators.clear(); assert.throws(finalize, code("AVATAR_REVIEW_SCOPE"));
    f.operators.add(f.reviewer.accountID);
    const response = await f.inspect(), input = decision(f, response);
    const decide = await f.coordinator.prepareDecision(input); f.operators.clear();
    assert.throws(decide, code("AVATAR_REVIEW_SCOPE"));
  } finally { f.close(); }
});

test("receipt cannot cross sessions or reviewer accounts, and a new inspection replaces the old", async () => {
  const f = await avatarReviewFixture();
  try {
    const response = await f.inspect(), input = decision(f, response), other = await f.session("synthetic.second-moderator");
    f.operators.add(other.accountID);
    await assert.rejects(() => f.reviewCall("prepareDecision", { ...input, accessToken: other.sessionToken }), code("AVATAR_REVIEW_STALE"));
    const next = await f.session("synthetic.moderator");
    await assert.rejects(() => f.reviewCall("prepareDecision", { ...input, accessToken: next.sessionToken }), code("AVATAR_REVIEW_STALE"));
    await f.inspect();
    await assert.rejects(() => f.reviewCall("prepareDecision", input), code("AVATAR_REVIEW_STALE"));
  } finally { f.close(); }
});

test("clear and supersession during a download cannot yield an inspection response", async () => {
  for (const action of ["clear", "select"]) {
    const f = await avatarReviewFixture();
    try {
      f.setDownloadHook(async () => {
        if (action === "clear") await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.pending.generation }));
        else await f.call("prepareUpload", f.upload());
      });
      await assert.rejects(() => f.inspect(), code("AVATAR_REVIEW_STALE"));
      assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1 WHERE verified=1").get().n, 0);
    } finally { f.close(); }
  }
});

test("a competing review invalidates inspection and cannot be overwritten by stale approval", async () => {
  const f = await avatarReviewFixture();
  try {
    const response = await f.inspect();
    await f.call("prepareReview", f.review(f.pending, "rejected"));
    await assert.rejects(() => f.reviewCall("prepareDecision", decision(f, response)), code("AVATAR_REVIEW_STALE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected");
  } finally { f.close(); }
});

test("corrupt bytes, headers, wrong record and foreign URLs cannot create a receipt", async () => {
  for (const mode of ["hash", "header", "url", "record"]) {
    const f = await avatarReviewFixture();
    try {
      if (mode === "hash") f.setDownloadHook(() => new Response(new Uint8Array([1, 2]), { headers: { "content-type": "image/jpeg" } }));
      if (mode === "header") f.setDownloadHook(() => new Response("bad", { status: 206, headers: { "content-type": "image/jpeg" } }));
      if (mode === "url") {
        const record = [...f.model.records.values()].find(r => r.recordType === "EchoesAvatarV1");
        record.fields.image.value.downloadURL = "https://evil.example.invalid/picture";
      }
      if (mode === "record") {
        const record = [...f.model.records.values()].find(r => r.recordType === "EchoesAvatarV1");
        record.recordChangeTag = "foreign-tag";
      }
      await assert.rejects(() => f.inspect(), code("AVATAR_REVIEW_RESPONSE"));
      assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1 WHERE verified=1").get().n, 0);
    } finally { f.close(); }
  }
});

test("cancelled and timed out providers retain admission until actual completion", async () => {
  for (const timed of [false, true]) {
    const f = await avatarReviewFixture(), held = gate();
    try {
      f.setDownloadHook(() => held.wait());
      const reviewer = timed ? f.makeReview({ timeoutMilliseconds: 100 }) : f.coordinator, input = f.inspection();
      const pending = reviewer.prepareInspection(input); await held.entered;
      if (!timed) f.cancel(input);
      await assert.rejects(pending, code("AVATAR_REVIEW_UNAVAILABLE"));
      await assert.rejects(() => reviewer.prepareQueue(f.input()), code("AVATAR_REVIEW_CAPACITY"));
      held.release();
      let resumed = false;
      for (let i = 0; i < 100; i++) {
        try { const result = await reviewer.prepareQueue(f.input()); result(); resumed = true; break; }
        catch (e) { if (e.code !== "AVATAR_REVIEW_CAPACITY") throw e; await new Promise(r => setTimeout(r, 2)); }
      }
      assert.equal(resumed, true);
      assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1 WHERE verified=1").get().n, 0);
    } finally { held.release(); f.close(); }
  }
});

test("receipt expiry, clock rollback and local cleanup continue without provider calls", async () => {
  const f = await avatarReviewFixture();
  try {
    const response = await f.inspect(), input = decision(f, response); f.advance(90000);
    await assert.rejects(() => f.reviewCall("prepareDecision", input), code("AVATAR_REVIEW_STALE"));
    const before = f.downloads.length; await purgeAvatarReviewReceipts(f.storage, f.clock);
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0); assert.equal(f.downloads.length, before);
    const fresh = await f.inspect(); f.advance(-1);
    await assert.rejects(() => f.reviewCall("prepareDecision", decision(f, fresh)), code("AVATAR_REVIEW_STALE"));
  } finally { f.close(); }
});

test("review receipts are removed for target erasure and reviewer erasure", async () => {
  for (const reviewer of [false, true]) {
    const f = await avatarReviewFixture();
    try {
      const response = await f.inspect();
      await f.beginDeletion(reviewer ? f.reviewer : f.signedIn, reviewer ? "synthetic.moderator" : "synthetic.user");
      await f.social.eraseOwner(reviewer ? f.reviewer.accountID : f.signedIn.accountID);
      assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
      await assert.rejects(() => f.reviewCall("prepareDecision", decision(f, response)), code(reviewer ? "AVATAR_REVIEW_SCOPE" : "AVATAR_REVIEW_STALE"));
    } finally { f.close(); }
  }
});

test("new inspections preserve a durable ten-per-minute reviewer budget", async () => {
  const f = await avatarReviewFixture();
  try {
    for (let i = 0; i < 10; i++) await f.inspect();
    const downloads = f.downloads.length, calls = f.model.checkpointRequests.length;
    await assert.rejects(() => f.inspect(), code("AVATAR_REVIEW_RATE"));
    assert.equal(f.downloads.length, downloads); assert.equal(f.model.checkpointRequests.length, calls);
    const restored = new AvatarReviewReceipts(f.storage, { clock: f.clock });
    await assert.rejects(() => f.reviewCall("prepareInspection", f.inspection(), f.makeReview({ receipts: restored })), code("AVATAR_REVIEW_RATE"));
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 1);
    f.advance(60000); assert.equal((await f.inspect()).status, 200);
  } finally { f.close(); }
});

test("closed schemas, default disabled service and failed clocks never dispatch downloads", async () => {
  const f = await avatarReviewFixture();
  try {
    for (const change of [{ url: "https://evil.invalid" }, { versionID: randomUUID() }, { recordType: "Users" }, { requestID: "bad" }])
      await assert.rejects(() => f.inspect(change), code("AVATAR_REVIEW_INPUT"));
    await assert.rejects(() => f.reviewCall("prepareInspection", f.inspection(), f.makeReview({ isEnabled: undefined })), code("AVATAR_REVIEW_UNAVAILABLE"));
    const broken = f.makeReview({ clock: () => { throw new Error("PRIVATE-CLOCK-DETAILS"); } });
    for (let i = 0; i < 2; i++) await assert.rejects(() => broken.prepareQueue(f.input()), code("AVATAR_REVIEW_UNAVAILABLE"));
    assert.equal(f.downloads.length, 0);
    assert.equal(avatarReviewerKey(f.reviewer.accountID).length, 64);
    assert.throws(() => new AvatarReviewCoordinator({}), code("AVATAR_REVIEW_INPUT"));
  } finally { f.close(); }
});

test("an unverified reservation never authorizes a decision, even with a known inspection identifier", async () => {
  const f = await avatarReviewFixture();
  try {
    const content = f.policy.reviewContent(f.signedIn.accountID, f.pending.requestID);
    const sessionKey = digest("echoes/avatar-review-session/v1\0" + f.reviewer.sessionToken);
    const reserved = await f.receipts.reserve(f.reviewer.accountID, sessionKey, content);
    assert.throws(() => f.receipts.get(f.reviewer.accountID, sessionKey, reserved.inspectionID), code("AVATAR_REVIEW_STALE"));
    await assert.rejects(() => f.reviewCall("prepareDecision", f.input({ inspectionID: reserved.inspectionID,
      decisionID: randomUUID(), verdict: "approved" })), code("AVATAR_REVIEW_STALE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "pending-review");
  } finally { f.close(); }
});

test("claimed decisions recover after ambiguous receipt writes and checkpoint failure without a new ID", async () => {
  for (const phase of ["claim", "finish", "checkpoint"]) {
    const f = await avatarReviewFixture();
    try {
      const response = await f.inspect(), body = decision(f, response), real = f.receipts;
      const proxy = Object.fromEntries(["get", "reserve", "confirm", "claim", "finish"].map(key => [key, (...args) => real[key](...args)]));
      if (phase !== "checkpoint") proxy[phase] = async (...args) => { await real[phase](...args); throw new Error("PRIVATE-IO-DETAIL"); };
      const checkpoint = phase === "checkpoint" ? { verify: (...args) => f.checkpoint.verify(...args), advance: async () => { throw new Error("PRIVATE-CHECKPOINT-DETAIL"); } } : f.checkpoint;
      await assert.rejects(() => f.reviewCall("prepareDecision", body, f.makeReview({ receipts: proxy, checkpoint })), code("AVATAR_REVIEW_UNAVAILABLE"));
      const row = f.db.prepare("SELECT * FROM avatar_review_receipts_v1").get(); assert.equal(row.decision_id, body.decisionID);
      const restored = f.makeReview({ receipts: new AvatarReviewReceipts(f.storage, { clock: f.clock }) });
      const result = await f.reviewCall("prepareDecision", body, restored);
      assert.equal(result.decisionID, body.decisionID); assert.equal(result.verdict, "approved");
      assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    } finally { f.close(); }
  }
});

test("target replacement during a durable decision claim prevents the review write", async () => {
  const f = await avatarReviewFixture();
  try {
    const response = await f.inspect(), body = decision(f, response), real = f.receipts;
    const proxy = Object.fromEntries(["get", "reserve", "confirm", "claim", "finish"].map(key => [key, (...args) => real[key](...args)]));
    proxy.claim = async (...args) => {
      const row = await real.claim(...args);
      await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.pending.generation }));
      return row;
    };
    await assert.rejects(() => f.reviewCall("prepareDecision", body, f.makeReview({ receipts: proxy })), code("AVATAR_REVIEW_STALE"));
    assert.equal(f.db.prepare("SELECT decision_id FROM avatar_jobs_v1 WHERE request_id=?").get(f.pending.requestID).decision_id, null);
  } finally { f.close(); }
});

test("queue is bounded to twenty active selections and finalization rejects changed moderation", async () => {
  const f = await avatarReviewFixture();
  try {
    for (let i = 0; i < 20; i++) {
      const owner = await f.session("synthetic.queued-" + i);
      await f.call("prepareUpload", f.upload({ accessToken: owner.sessionToken, expectedGeneration: 0 }));
    }
    const queued = await f.coordinator.prepareQueue(f.input()), all = f.policy.reviewQueue(); assert.equal(all.length, 20);
    const selected = all[0];
    await f.call("prepareReview", f.review(selected, "rejected", { accountID: selected.accountID }));
    assert.throws(queued, code("AVATAR_REVIEW_STALE"));
    const next = await f.reviewCall("prepareQueue", f.input()); assert.equal(next.items.length, 20);
    assert.equal(next.items.some(item => item.requestID === selected.requestID), false);
    assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("receipt storage has a global capacity and expiry releases it without images or provider calls", async () => {
  const f = await avatarReviewFixture();
  try {
    const content = f.policy.reviewContent(f.signedIn.accountID, f.pending.requestID), sessionKey = digest("synthetic-capacity-session");
    for (let i = 0; i < 256; i++) await f.receipts.reserve(randomUUID(), sessionKey, content);
    await assert.rejects(() => f.receipts.reserve(randomUUID(), sessionKey, content), code("AVATAR_REVIEW_CAPACITY"));
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 256);
    f.advance(90000); await purgeAvatarReviewReceipts(f.storage, f.clock);
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
    await f.receipts.reserve(randomUUID(), sessionKey, content);
    assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});
