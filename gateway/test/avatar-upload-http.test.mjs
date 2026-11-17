import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { withAvatarMetadata } from "./support/avatar-image-fixture.mjs";
import { createGatewayHTTPHandler } from "../src/gateway-http.mjs";
import { createGatewayRuntime, activeGatewayConfiguration } from "../src/gateway-runtime.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";
import { AvatarPublicationCoordinator } from "../src/avatar-publication-coordinator.mjs";
import { avatarIntentHeader, avatarMutationHeaders, avatarMutationInput, avatarMutationSnapshot } from "../src/avatar-upload-http.mjs";

const empty = () => ({ generation: 0, requestID: null, versionID: null, publishedVersionID: null, status: "none", reviewRevision: null });
const code = value => ({ code: value });
const turn = () => new Promise(resolve => setImmediate(resolve));
async function json(response, status = 200) {
  const body = await response.json(); assert.equal(response.status, status, JSON.stringify(body));
  assert.equal(response.headers.get("Cache-Control"), "no-store"); assert.equal(body.protocolVersion, 1); return body;
}
function heldStream() {
  let controller, pulled, cancelled = false;
  const started = new Promise(resolve => { pulled = resolve; });
  const stream = new ReadableStream({ start(value) { controller = value; }, pull() { pulled(); }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
  return { stream, started, close() { try { controller.close(); } catch {} }, get cancelled() { return cancelled; } };
}

test("binary upload normalizes source on the server and returns pending moderation without provider metadata", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    const intent = f.body("upload"), source = withAvatarMetadata(f.sourceBytes);
    const result = await json(await f.call("upload", intent, { rawBody: source }));
    assert.equal(result.status, "pending-review"); assert.equal(result.generation, 1); assert.equal(result.versionID, intent.versionID);
    assert.equal(result.publishedVersionID, null); assert.equal(f.assetCalls.filter(c => c.phase === "upload").length, 2);
    assert.deepEqual(Object.keys(result).sort(), ["protocolVersion", ...Object.keys(empty())].sort());
    assert.doesNotMatch(JSON.stringify(result), /SYNTHETIC-PRIVATE|receipt|https:|fileChecksum/);
    for (const bytes of f.uploadedBytes.values()) assert.equal(new TextDecoder().decode(bytes).includes("SYNTHETIC-GPS"), false);
    assert.equal(new TextDecoder().decode(source).includes("SYNTHETIC-GPS"), true);
  } finally { f.close(); }
});

test("concrete runtime and fixed edge upload, recover, publish after trusted review and clear with shared durable policy", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  try {
    const intent = f.body("upload"), staged = await json(await f.edge("upload", intent));
    assert.equal(staged.status, "pending-review"); assert.equal(staged.publishedVersionID, null);
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 2);
    assert.equal((await json(await f.edge("recover", { requestID: intent.requestID }))).status, "pending-review");
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 2);
    const review = await f.coordinator.prepareReview(f.review(staged)); await f.checkpoint.advance(); review();
    const published = await json(await f.edge("publish", { requestID: intent.requestID }));
    assert.equal(published.status, "published"); assert.equal(published.publishedVersionID, intent.versionID);
    const cleared = await json(await f.edge("clear")); assert.equal(cleared.status, "none"); assert.equal(cleared.generation, 2);
    assert.equal(cleared.versionID, null); assert.deepEqual(await json(await f.edge("status")), cleared);
    assert.equal(f.transfers.length, 4);
    const envelopes = f.db.prepare("SELECT receipt_envelope FROM avatar_asset_transfers_v1").all();
    assert.ok(envelopes.length === 2 && envelopes.every(row => !JSON.stringify(row).includes("SYNTHETIC-PRIVATE")));
  } finally { f.close(); }
});

test("lost record ACK recovers the same upload over HTTP without uploading files again", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true }); let dropped = false;
  try {
    f.setRecordHook(call => {
      if (!dropped && call.operation === "modify" && call.body.operations[0].record.recordType === "EchoesAvatarV1") { dropped = true; throw new Error("synthetic lost ACK"); }
    });
    const intent = f.body("upload"); await json(await f.edge("upload", intent), 503); assert.equal(dropped, true);
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 2);
    const recovered = await json(await f.edge("recover", { requestID: intent.requestID }));
    assert.equal(recovered.status, "pending-review"); assert.equal(recovered.requestID, intent.requestID);
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 2);
  } finally { f.close(); }
});

test("unknown asset ACK remains pending and neither recovery nor exact replay reuploads that file", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  try {
    f.onAsset(call => { if (call.phase === "upload") throw new Error("synthetic unknown transfer"); });
    const intent = f.body("upload"); await json(await f.edge("upload", intent), 503);
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 1);
    assert.equal((await json(await f.edge("recover", { requestID: intent.requestID }), 409)).error, "AVATAR_PENDING");
    assert.equal((await json(await f.edge("upload", intent), 409)).error, "AVATAR_PENDING");
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 1);
  } finally { f.close(); }
});

test("upload feature denies before budget, body or checkpoint and cancels the unread stream", async () => {
  const f = await avatarUploadHTTPFixture(), held = heldStream();
  try {
    f.setFeature(false);
    assert.equal((await json(await f.call("upload", {}, { rawBody: held.stream }), 503)).error, "FEATURE_DISABLED");
    assert.deepEqual(f.counts(), { budgets: 0, accountLimits: 0, verifies: 0 });
    assert.equal(held.cancelled, true); assert.equal(f.assetCalls.length, 0);
  } finally { held.close(); f.close(); }
});

test("runtime upload activation requires community, exact server hosts and an actual codec factory", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  try {
    for (const patch of [{ AVATAR_UPLOAD_ENABLED: "yes" }, { COMMUNITY_ENABLED: "0" }, { AVATAR_UPLOAD_HOSTS_JSON: "[]" },
      { AVATAR_UPLOAD_HOSTS_JSON: '["*.icloud.com"]' }, { AVATAR_UPLOAD_HOSTS_JSON: '["https://a.icloud.com"]' }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...patch }, f.clock()), null);
    assert.throws(() => createGatewayRuntime(f.storage, f.env, { ...f.runtimeOptions, avatarNormalizerFactory: undefined }));
    assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarReadEnabled, false);
    let calls = 0;
    createGatewayRuntime(f.storage, { ...f.env, AVATAR_UPLOAD_ENABLED: "0" }, { ...f.runtimeOptions, avatarNormalizerFactory() { calls++; throw new Error(); } });
    assert.equal(calls, 0);
  } finally { f.close(); }
});

test("closed intent headers reject owner, URL, receipt, consent and generation attacks before file consumption", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    for (const changes of [{ accountID: randomUUID() }, { uploadURL: "https://attacker.invalid" }, { receipt: "forged" }, { consentVersion: 0 },
      { expectedGeneration: -1 }, { expectedGeneration: Number.MAX_SAFE_INTEGER }, { requestID: "bad" }, { versionID: "bad" }, { review: "approved" }]) {
      const value = f.body("upload", changes); assert.throws(() => avatarMutationInput("upload", value), code("AVATAR_INPUT"));
      assert.throws(() => avatarMutationHeaders(f.request("upload", changes), "upload"), code("AVATAR_INPUT"));
    }
    const held = heldStream();
    assert.equal((await json(await f.call("upload", { accountID: randomUUID() }, { rawBody: held.stream }), 400)).error, "AVATAR_INPUT");
    assert.equal(held.cancelled, true); assert.equal(f.counts().accountLimits, 0); assert.equal(f.counts().verifies, 0);
  } finally { f.close(); }
});

test("media, encoding, token and declared size fail before reading a body or checkpoint", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    for (const [headers, status] of [[{ "Content-Type": "multipart/form-data" }, 415], [{ "Content-Encoding": "gzip" }, 415],
      [{ "Content-Length": "256001" }, 413], [{ "Content-Length": "0" }, 413], [{ Authorization: "Bearer fake" }, 401]]) {
      const held = heldStream(); await json(await f.call("upload", {}, { rawBody: held.stream, headers }), status);
      assert.equal(held.cancelled, true);
    }
    assert.equal(f.counts().verifies, 0); assert.equal(f.counts().accountLimits, 0);
  } finally { f.close(); }
});

test("revoked session is rejected before file body and invalidation after durable quota is rechecked", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    const original = f.dependencies.limits.consumeAvatarMutation;
    f.dependencies.limits.consumeAvatarMutation = async (...args) => {
      await original(...args); f.db.prepare("UPDATE auth_accounts_v1 SET disabled=1 WHERE account_id=?").run(f.signedIn.accountID);
    };
    const held = heldStream(); await json(await f.call("upload", {}, { rawBody: held.stream }), 401);
    assert.equal(held.cancelled, true); assert.equal(f.counts().verifies, 0); assert.equal(f.assetCalls.length, 0);
  } finally { f.close(); }
});

test("persisted account attempt quota survives reconstruction and network rotation while clear remains available", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    for (let i = 0; i < 3; i++) await json(await f.call("upload", {}, { rawBody: new Uint8Array([1, 2, 3]), budget: String(i).repeat(64) }), 400);
    const reconstructed = createGatewayHTTPHandler({ ...f.dependencies, limits: new GatewayLimits(f.storage, { clock: f.clock }) });
    const held = heldStream(), request = f.request("upload", {}, { rawBody: held.stream });
    assert.equal((await json(await reconstructed(request, "f".repeat(64)), 429)).error, "RATE_LIMITED");
    assert.equal(held.cancelled, true);
    const clear = await json(await reconstructed(f.request("clear"), "e".repeat(64))); assert.equal(clear.status, "none");
    const rows = f.db.prepare("SELECT key_hash FROM gateway_windows_v1 WHERE kind='avatar-upload'").all();
    assert.equal(rows.length, 1); assert.ok(rows.every(r => /^[a-f0-9]{64}$/.test(r.key_hash) && r.key_hash !== f.signedIn.accountID));
  } finally { f.close(); }
});

test("binary intake admits only one held body while bounded control operations remain independent", async () => {
  const f = await avatarUploadHTTPFixture({ inputTimeoutMilliseconds: 500 }), held = heldStream(), controller = new AbortController();
  try {
    const first = f.call("upload", {}, { rawBody: held.stream, signal: controller.signal }); await held.started;
    assert.equal((await json(await f.call("upload"), 429)).error, "AVATAR_RATE");
    assert.equal((await json(await f.call("status"))).status, "none");
    controller.abort(); await json(await first, 503); assert.equal(held.cancelled, true);
  } finally { controller.abort(); held.close(); f.close(); }
});

test("absolute timeout retains admission until an ignoring coordinator settles", async () => {
  let resolve, entered; const started = new Promise(r => { entered = r; }); const pending = new Promise(r => { resolve = r; }); let first = true;
  const f = await avatarUploadHTTPFixture({ avatarUploadTimeoutMilliseconds: 100, avatarPublication: { async prepareUpload() {
    if (first) { first = false; entered(); await pending; } return empty;
  } } });
  try {
    const operation = f.call("upload"); await started; await json(await operation, 503);
    assert.equal((await json(await f.call("upload"), 429)).error, "AVATAR_RATE");
    resolve(); await turn(); assert.equal((await json(await f.call("upload"))).status, "none");
  } finally { resolve(); f.close(); }
});

test("body deadline cancels stalled input before any provider operation", async () => {
  const f = await avatarUploadHTTPFixture({ inputTimeoutMilliseconds: 10 }), held = heldStream();
  try {
    await json(await f.call("upload", {}, { rawBody: held.stream }), 503);
    assert.equal(held.cancelled, true); assert.equal(f.counts().verifies, 0); assert.equal(f.assetCalls.length, 0);
  } finally { held.close(); f.close(); }
});

test("actual byte overflow, mismatched length and pathological chunks cannot reach the codec", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    await json(await f.call("upload", {}, { rawBody: new Uint8Array(256001) }), 413);
    await json(await f.call("upload", {}, { headers: { "Content-Length": String(f.sourceBytes.length + 1) } }), 400);
    const stream = new ReadableStream({ start(c) { for (let i = 0; i < 129; i++) c.enqueue(new Uint8Array([1])); c.close(); } });
    await json(await f.call("upload", {}, { rawBody: stream }), 400);
    assert.equal(f.assetCalls.length, 0); assert.equal(f.counts().verifies, 0);
  } finally { f.close(); }
});

test("control input is closed, fatal UTF8, at most 512 bytes and cannot carry intent metadata", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    for (const rawBody of ['{"accountID":"forged"}', new Uint8Array([0xff]), '"not an object"', " ".repeat(513)]) await json(await f.call("status", {}, { rawBody }), rawBody.length === 513 ? 413 : 400);
    await json(await f.call("status", {}, { headers: { [avatarIntentHeader]: "{}" } }), 400);
    assert.equal(f.counts().verifies, 0);
  } finally { f.close(); }
});

test("last checkpoint feature switch and changed intent prevent a stale successful upload response", async () => {
  for (const change of ["feature", "clear"]) {
    const f = await avatarUploadHTTPFixture();
    try {
      f.afterLastAdvance(async () => {
        if (change === "feature") f.setFeature(false);
        else await f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: 1 });
      });
      const response = await f.call("upload"); assert.equal((await json(response, change === "feature" ? 503 : 409)).error, change === "feature" ? "FEATURE_DISABLED" : "AVATAR_STALE");
    } finally { f.close(); }
  }
});

test("async or private-field finalizers are never presented as successful mutation snapshots", async () => {
  for (const final of [() => ({ ...empty(), receipt: "private" }), async () => empty(), () => null]) {
    const f = await avatarUploadHTTPFixture({ avatarPublication: { async prepareUpload() { return final; } } });
    try { assert.equal((await json(await f.call("upload"), 503)).error, "AVATAR_RESPONSE"); } finally { f.close(); }
  }
  assert.throws(() => avatarMutationSnapshot({ ...empty(), publishedVersionID: randomUUID() }), code("AVATAR_RESPONSE"));
});

test("fixed edge forwards intent but removes spoofed cookie, budget and provider response headers", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  try {
    const intent = f.body("upload"); await json(await f.edge("upload", intent, { headers: { Cookie: "private", "X-Echoes-Request-Budget": "spoof" } }));
    const headers = f.forwarded[0].headers;
    assert.equal(headers.has("Cookie"), false); assert.notEqual(headers.get("X-Echoes-Request-Budget"), "spoof");
    assert.deepEqual(JSON.parse(headers.get(avatarIntentHeader)), intent);
    f.env.AVATAR_UPLOAD_HOSTS_JSON = '["changed.icloud-content.com"]';
    assert.equal((await json(await f.edge("status"), 503)).error, "FEATURE_DISABLED");
  } finally { f.close(); }
});

test("edge owns error JSON before request abort and rejects private success fields", async () => {
  for (const malformed of [false, true]) {
    const f = await avatarUploadHTTPFixture({ runtime: true });
    try {
      f.env.COMMUNITY_AUTHORITY.get = () => ({ fetch(request) {
        const bytes = new TextEncoder().encode(JSON.stringify(malformed ? { protocolVersion: 1, ...empty(), receipt: "private" } : { protocolVersion: 1, error: "AVATAR_PENDING" }));
        const body = new ReadableStream({ start(c) { c.enqueue(bytes); c.close(); request.signal.addEventListener("abort", () => { try { c.error(new Error("closed upstream")); } catch {} }); } });
        return new Response(body, { status: malformed ? 200 : 409, headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Set-Cookie": "private" } });
      } });
      const response = await f.edge("status"); assert.equal(response.headers.has("Set-Cookie"), false);
      assert.equal((await json(response, malformed ? 503 : 409)).error, malformed ? "AVATAR_RESPONSE" : "AVATAR_PENDING");
    } finally { f.close(); }
  }
});

test("control admission is bounded to four held requests and operator review has no public route", async () => {
  const f = await avatarUploadHTTPFixture({ inputTimeoutMilliseconds: 500 }), held = [];
  try {
    for (let i = 0; i < 4; i++) { const input = heldStream(), controller = new AbortController();
      const result = f.call("status", {}, { rawBody: input.stream, signal: controller.signal }); held.push({ input, controller, result }); await input.started; }
    assert.equal((await json(await f.call("status"), 429)).error, "AVATAR_RATE");
    assert.equal((await json(await f.call("review", { verdict: "approved" }), 404)).error, "NOT_FOUND");
  } finally {
    for (const h of held) { h.controller.abort(); h.input.close(); await h.result; } f.close();
  }
});

test("asynchronous authentication is rejected at both pre-body checks without unhandled rejections", async () => {
  for (const asyncCall of [1, 2]) {
    let calls = 0, accountID;
    const f = await avatarUploadHTTPFixture({ authentication: { issueChallenge() {}, authorize() {
      if (++calls === asyncCall) return Promise.reject(new Error("synthetic async source")); return { accountID };
    } } });
    accountID = f.signedIn.accountID;
    const held = heldStream();
    try {
      assert.equal((await json(await f.call("upload", {}, { rawBody: held.stream }), 401)).error, "INVALID_SESSION");
      assert.equal(held.cancelled, true); assert.equal(f.counts().verifies, 0); await turn();
    } finally { held.close(); f.close(); }
  }
});

test("failed account admission durability cannot consume any file bytes or reach a checkpoint", async () => {
  const f = await avatarUploadHTTPFixture(), held = heldStream();
  try {
    f.dependencies.limits.consumeAvatarMutation = async (...args) => {
      const old = f.storage.sync; f.storage.sync = async () => { throw new Error("synthetic sync failure"); };
      try { return await f.limits.consumeAvatarMutation(...args); } finally { f.storage.sync = old; }
    };
    assert.equal((await json(await f.call("upload", {}, { rawBody: held.stream }), 503)).error, "LIMIT_UNAVAILABLE");
    assert.equal(held.cancelled, true); assert.equal(f.counts().verifies, 0); assert.equal(f.assetCalls.length, 0);
  } finally { held.close(); f.close(); }
});

test("empty or non-byte chunks fail immediately instead of starving input timers", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    for (const value of [new Uint8Array(0), "not bytes"]) {
      let cancelled = false, pulls = 0;
      const rawBody = new ReadableStream({ pull(c) { pulls++; c.enqueue(value); }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
      assert.equal((await json(await f.call("status", {}, { rawBody }), 400)).error, "AVATAR_INPUT");
      assert.equal(cancelled, true); assert.equal(pulls, 1);
    }
    assert.equal(f.counts().verifies, 0);
  } finally { f.close(); }
});

test("disabling new uploads preserves status and withdrawal while existing photo reads remain enabled", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true, readEnabled: true });
  try {
    const staged = await json(await f.edge("upload"));
    const review = await f.coordinator.prepareReview(f.review(staged)); await f.checkpoint.advance(); review();
    assert.equal((await json(await f.edge("publish", { requestID: staged.requestID }))).status, "published");
    f.env.AVATAR_UPLOAD_ENABLED = "0";
    assert.equal((await json(await f.edge("upload"), 503)).error, "FEATURE_DISABLED");
    assert.equal((await json(await f.edge("status"))).status, "published");
    assert.equal((await json(await f.edge("clear"))).status, "none");
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    assert.equal(f.transfers.filter(c => c.phase === "upload").length, 2);
  } finally { f.close(); }
});

test("read-only runtime constructs real status and withdrawal without a codec or asset-upload capability", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true, readEnabled: true });
  try {
    f.env.AVATAR_UPLOAD_ENABLED = "0";
    const runtime = createGatewayRuntime(f.storage, f.env, { ...f.runtimeOptions, avatarNormalizerFactory: undefined });
    assert.equal((await json(await runtime.handle(f.request("status"), "a".repeat(64)))).status, "none");
    assert.equal((await json(await runtime.handle(f.request("clear"), "a".repeat(64)))).generation, 1);
    assert.equal((await json(await runtime.handle(f.request("upload"), "a".repeat(64)), 503)).error, "FEATURE_DISABLED");
    assert.equal(f.transfers.length, 0);
  } finally { f.close(); }
});

test("withdrawal-only coordinator cannot upload, recover, publish or acquire operator review", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    const coordinator = new AvatarPublicationCoordinator({ state: f.policy, authentication: f.state, communityState: f.social,
      profileRepository: f.profiles, checkpoint: f.checkpoint, isEnabled: () => true, withdrawalOnly: true });
    for (const method of ["prepareUpload", "prepareRecovery", "preparePublish", "prepareReview"]) await assert.rejects(coordinator[method]({}), code("AVATAR_SCOPE"));
    assert.equal(f.assetCalls.length, 0); assert.equal((await coordinator.prepareStatus(f.credentials()))().status, "none");
  } finally { f.close(); }
});
