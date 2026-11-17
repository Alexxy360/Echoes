import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarReviewHTTPFixture } from "./support/avatar-review-http-fixture.mjs";
import { AvatarReviewCoordinator } from "../src/avatar-review-coordinator.mjs";
import { purgeAvatarReviewReceipts } from "../src/avatar-review-state.mjs";
import { avatarReviewInput, avatarReviewResult, avatarReviewEdgeResponse, avatarReviewDeadline } from "../src/avatar-review-http.mjs";

const json = async (response, status = 200) => {
  const body = await response.json(); assert.equal(response.status, status, JSON.stringify(body)); return body;
};
async function selection(f, verdict = "approved") {
  const queued = await json(await f.edge("queue")); assert.equal(queued.items.length, 1);
  return { ...queued.items[0], decisionID: randomUUID(), verdict };
}
async function apply(f, recovery) {
  const image = await f.edge("inspect", { accountID: recovery.accountID, requestID: recovery.requestID });
  assert.equal(image.status, 200); const proof = f.reviewMetadata(image); await image.arrayBuffer();
  return json(await f.edge("decide", { inspectionID: proof.inspectionID, decisionID: recovery.decisionID, verdict: recovery.verdict }));
}

test("read-only recovery confirms exact lost ACK after receipt expiry cleanup and runtime reconstruction", async () => {
  for (const verdict of ["approved", "rejected"]) {
    const f = await avatarReviewHTTPFixture({ runtime: true });
    try {
      const input = await selection(f, verdict), result = await apply(f, input);
      f.advance(90_000); await purgeAvatarReviewReceipts(f.storage, f.clock);
      assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
      const downloads = f.downloads.length, prior = f.policy.snapshot(input.accountID);
      const recovery = await json(await f.edge("recover", input));
      assert.deepEqual(recovery, { protocolVersion: 1, schemaVersion: 1, ...input, outcome: "confirmed", revision: result.revision });
      const coordinator = new AvatarReviewCoordinator(f.configuration);
      assert.equal((await f.reviewCall("prepareRecovery", f.input(input), coordinator)).revision, result.revision);
      assert.equal(f.downloads.length, downloads); assert.deepEqual(f.policy.snapshot(input.accountID), prior);
      assert.equal(prior.publishedVersionID, null);
      assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
    } finally { f.close(); }
  }
});

test("recovery never applies an unsent intent and needs no inspection receipt", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true });
  try {
    const input = await selection(f), before = f.policy.snapshot(input.accountID);
    const result = await json(await f.edge("recover", input));
    assert.equal(result.outcome, "not-applied"); assert.equal(result.revision, null);
    assert.deepEqual(f.policy.snapshot(input.accountID), before); assert.equal(f.downloads.length, 0);
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
  } finally { f.close(); }
});

test("recovery distinguishes ambiguous claim from applied decision after finish or checkpoint ACK loss", async () => {
  for (const phase of ["claim", "finish", "checkpoint"]) {
    const f = await avatarReviewHTTPFixture();
    try {
      const input = await selection(f), response = await f.inspect(), proof = f.reviewMetadata(response); await response.arrayBuffer();
      const real = f.receipts, proxy = Object.fromEntries(["get", "reserve", "confirm", "claim", "finish"].map(k => [k, (...args) => real[k](...args)]));
      if (phase !== "checkpoint") proxy[phase] = async (...args) => { await real[phase](...args); throw new Error("PRIVATE-ACK-DETAIL"); };
      const checkpoint = phase === "checkpoint" ? { verify: (...a) => f.checkpoint.verify(...a), advance: async () => { throw new Error("PRIVATE-CHECKPOINT"); } } : f.checkpoint;
      const failing = f.makeReview({ receipts: proxy, checkpoint });
      await assert.rejects(() => f.reviewCall("prepareDecision", f.input({ inspectionID: proof.inspectionID, decisionID: input.decisionID, verdict: input.verdict }), failing), e => e.code === "AVATAR_REVIEW_UNAVAILABLE");
      await f.checkpoint.advance(); f.advance(90_000); await purgeAvatarReviewReceipts(f.storage, f.clock);
      const result = await json(await f.call("recover", input));
      assert.equal(result.outcome, phase === "claim" ? "not-applied" : "confirmed");
      assert.equal(f.policy.snapshot(input.accountID).publishedVersionID, null);
      assert.equal(f.downloads.length, 1);
    } finally { f.close(); }
  }
});

test("recovery binds every selection and decision field and never confirms a different operator", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    const input = await selection(f); await apply(f, input);
    const other = await f.session("synthetic.second.moderator"); f.operators.add(other.accountID);
    assert.equal((await json(await f.call("recover", input, { token: other.sessionToken }))).outcome, "superseded");
    for (const patch of [
      { accountID: randomUUID() }, { requestID: randomUUID() }, { versionID: randomUUID() },
      { generation: input.generation + 1 }, { reviewRevision: randomUUID() }, { decisionID: randomUUID() }, { verdict: "rejected" },
    ]) {
      const result = await json(await f.call("recover", { ...input, ...patch }));
      assert.equal(result.outcome, "superseded"); assert.equal(result.revision, null);
    }
  } finally { f.close(); }
});

test("renewed session of the same moderator can recover metadata without renewing receipt", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    const input = await selection(f), result = await apply(f, input);
    const renewed = await f.session("synthetic.moderator"); assert.equal(renewed.accountID, f.reviewer.accountID);
    f.advance(90_000); await purgeAvatarReviewReceipts(f.storage, f.clock);
    const recovered = await json(await f.call("recover", input, { token: renewed.sessionToken }));
    assert.equal(recovered.outcome, "confirmed"); assert.equal(recovered.revision, result.revision);
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
  } finally { f.close(); }
});

test("withdrawal replacement and target erasure yield superseded without a historical success claim", async () => {
  for (const mode of ["clear", "replace", "erase"]) {
    const f = await avatarReviewHTTPFixture({ runtime: true });
    try {
      const input = await selection(f); await apply(f, input);
      if (mode === "erase") {
        f.db.prepare("UPDATE auth_accounts_v1 SET disabled=1 WHERE account_id=?").run(input.accountID);
        f.db.prepare("DELETE FROM avatar_jobs_v1 WHERE account_id=?").run(input.accountID);
      } else if (mode === "clear") {
        await f.policy.clear({ accountID: input.accountID, requestID: randomUUID(), expectedGeneration: input.generation });
      } else {
        await f.policy.select({ accountID: input.accountID, requestID: randomUUID(), versionID: randomUUID(),
          expectedGeneration: input.generation, sourceHash: "a".repeat(64), consentVersion: 1 });
      }
      await f.checkpoint.advance();
      const result = await json(await f.edge("recover", input)); assert.equal(result.outcome, "superseded"); assert.equal(result.revision, null);
    } finally { f.close(); }
  }
});

test("recovery finalizer refuses a state or operator change after checkpoint", async () => {
  for (const mode of ["role", "state"]) {
    const f = await avatarReviewHTTPFixture();
    try {
      const input = await selection(f), final = await f.coordinator.prepareRecovery(f.input(input));
      await f.checkpoint.advance();
      if (mode === "role") f.operators.clear();
      else {
        await f.policy.clear({ accountID: input.accountID, requestID: randomUUID(), expectedGeneration: input.generation });
        await f.checkpoint.advance();
      }
      assert.throws(final, e => e.code === (mode === "role" ? "AVATAR_REVIEW_SCOPE" : "AVATAR_REVIEW_STALE"));
    } finally { f.close(); }
  }
});

test("recovery denies ordinary sessions and consumed operator quota before reading body", async () => {
  for (const limited of [false, true]) {
    const f = await avatarReviewHTTPFixture(); let pulled = false, cancelled = false;
    const stream = new ReadableStream({ pull() { pulled = true; }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
    try {
      if (limited) for (let i = 0; i < 30; i++) await f.limits.consumeAvatarReview(f.reviewer.accountID);
      const response = await f.call("recover", {}, { rawBody: stream, token: limited ? f.reviewer.sessionToken : f.signedIn.sessionToken });
      const result = await json(response, limited ? 429 : 403);
      assert.equal(result.error, limited ? "RATE_LIMITED" : "AVATAR_REVIEW_SCOPE");
      assert.equal(pulled, false); assert.equal(cancelled, true); assert.equal(f.downloads.length, 0);
    } finally { f.close(); }
  }
});

test("recovery requests and responses have closed keys safe generations and exact correlation", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    const input = await selection(f), good = { schemaVersion: 1, ...input, outcome: "not-applied", revision: null };
    assert.deepEqual(avatarReviewResult("recover", good, input), good);
    for (const patch of [{ generation: 0 }, { generation: true }, { generation: 1.5 }, { generation: Number.MAX_SAFE_INTEGER },
      { reviewRevision: "bad" }, { decisionID: "bad" }, { verdict: "published" }, { operatorID: randomUUID() }, { downloadURL: "https://PRIVATE.invalid" }])
      assert.throws(() => avatarReviewInput("recover", { ...input, ...patch }));
    for (const patch of [{ outcome: "unknown" }, { revision: randomUUID() }, { outcome: "confirmed" },
      { outcome: "confirmed", revision: input.reviewRevision }, { decisionID: randomUUID() }, { accountID: randomUUID() }, { private: "PRIVATE" }])
      assert.throws(() => avatarReviewResult("recover", { ...good, ...patch }, input));
    const missing = { ...good }; delete missing.revision; assert.throws(() => avatarReviewResult("recover", missing, input));
    const response = Response.json({ protocolVersion: 1, ...good, private: "PRIVATE" }, { headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
    const deadline = avatarReviewDeadline();
    try { await assert.rejects(() => avatarReviewEdgeResponse(response, "recover", deadline), e => e.code === "AVATAR_REVIEW_RESPONSE"); }
    finally { deadline.close(); }
  } finally { f.close(); }
});
