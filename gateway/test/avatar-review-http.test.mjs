import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarReviewHTTPFixture } from "./support/avatar-review-http-fixture.mjs";
import { activeGatewayConfiguration, createGatewayRuntime, forwardGatewayRequest } from "../src/gateway-runtime.mjs";
import { avatarReviewers, avatarReviewInput, avatarReviewResult, avatarReviewDeadline, avatarReviewEdgeResponse } from "../src/avatar-review-http.mjs";
import { avatarReviewHeader } from "../src/avatar-review-coordinator.mjs";
import { digest } from "../src/public-record-schema.mjs";
const json = async (response, status = 200) => { const body = await response.json(); assert.equal(response.status, status, JSON.stringify(body)); assert.equal(body.protocolVersion, 1); return body; };
function stream() {
  let controller, pulled = false, cancelled = false;
  const raw = new ReadableStream({ start(c) { controller = c; }, pull() { pulled = true; }, cancel() { cancelled = true; } }, { highWaterMark: 0 });
  return { raw, get pulled() { return pulled; }, get cancelled() { return cancelled; }, close() { try { controller.close(); } catch {} } };
}
const decide = (response, changes = {}) => ({ inspectionID: JSON.parse(response.headers.get(avatarReviewHeader)).inspectionID, decisionID: randomUUID(), verdict: "approved", ...changes });

test("operator HTTP queues and inspects the actual image before an exact decision without publication", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    const queue = await json(await f.call("queue")); assert.equal(queue.items.length, 1);
    assert.equal(queue.items[0].requestID, f.pending.requestID);
    const image = await f.call("inspect"); assert.equal(image.status, 200);
    const manifest = JSON.parse(image.headers.get("x-echoes-avatar-manifest"));
    assert.equal(digest(new Uint8Array(await image.arrayBuffer())), manifest.sha256);
    const body = decide(image), result = await json(await f.call("decide", body));
    assert.equal(result.verdict, "approved"); assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    assert.deepEqual(await json(await f.call("decide", body)), result);
    assert.equal(f.counts().scheduled, 4);
    assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("concrete Runtime and fixed edge preserve closed inspection headers and canonical decision JSON", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true });
  try {
    const queue = await json(await f.edge("queue")); assert.equal(queue.items.length, 1);
    const image = await f.edge("inspect"); assert.equal(image.status, 200);
    assert.equal(image.headers.get("cache-control"), "private, no-store"); assert.equal(image.headers.get("x-content-type-options"), "nosniff");
    assert.equal(image.headers.has("set-cookie"), false);
    const request = decide(image); await image.arrayBuffer();
    const approved = await json(await f.edge("decide", request)); assert.equal(approved.verdict, "approved");
    assert.deepEqual(await json(await f.edge("decide", request)), approved);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "approved");
    assert.equal(f.forwarded.length, 4);
    for (const req of f.forwarded) assert.match(req.headers.get("x-echoes-request-budget"), /^[a-f0-9]{64}$/);
  } finally { f.close(); }
});

test("disabled feature and ordinary sessions stop before body, account budget and checkpoint", async () => {
  for (const mode of ["disabled", "ordinary", "async-role", "async-auth", "async-feature"]) {
    const settings = mode === "async-role" ? { isAvatarReviewer: async () => true } : mode === "async-feature" ? { isAvatarReviewEnabled: () => Promise.reject(new Error("PRIVATE-FLAG")) } : mode === "async-auth" ? { authentication: { issueChallenge() {}, authorize: async () => ({ accountID: randomUUID() }) } } : {};
    const f = await avatarReviewHTTPFixture(settings), held = stream();
    try {
      if (mode === "disabled") f.setFeature(false);
      const response = await f.call("inspect", {}, { rawBody: held.raw, token: mode === "ordinary" ? f.signedIn.sessionToken : undefined });
      await json(response, ["disabled", "async-feature"].includes(mode) ? 503 : mode === "async-auth" ? 401 : 403);
      assert.equal(held.pulled, false); assert.equal(held.cancelled, true);
      assert.equal(f.counts().accountLimits, 0); assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
    } finally { held.close(); f.close(); }
  }
});

test("role and account identity are rechecked after durable admission and final checkpoint", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    f.afterLastAdvance(() => f.operators.clear());
    const result = await json(await f.call("inspect"), 403); assert.equal(result.error, "AVATAR_REVIEW_SCOPE");
    assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("review activation requires exact bounded reviewer IDs, community and download hosts", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true });
  try {
    for (const patch of [{ AVATAR_REVIEW_ENABLED: "yes" }, { AVATAR_REVIEWER_IDS_JSON: "[]" }, { AVATAR_REVIEWER_IDS_JSON: '["bad"]' },
      { AVATAR_REVIEWER_IDS_JSON: JSON.stringify(Array(17).fill(f.reviewer.accountID)) }, { COMMUNITY_ENABLED: "0" },
      { AVATAR_DOWNLOAD_HOSTS_JSON: "[]" }, { AVATAR_DOWNLOAD_HOSTS_JSON: '["*.icloud.com"]' }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...patch }, f.clock()), null);
    assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarReviewEnabled, true);
    assert.equal(activeGatewayConfiguration({ ...f.env, AVATAR_REVIEW_ENABLED: "0", AVATAR_REVIEWER_IDS_JSON: "[]" }, f.clock()).avatarReviewEnabled, false);
    assert.throws(() => avatarReviewers(JSON.stringify([f.reviewer.accountID, f.reviewer.accountID])));
    assert.equal(createGatewayRuntime(f.storage, f.env, f.runtimeOptions).handle instanceof Function, true);
  } finally { f.close(); }
});

test("closed review requests cannot supply role, owner decisions, revision, URL or provider metadata", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    for (const [action, extra] of [["queue", { operator: true }], ["inspect", { url: "https://evil.invalid" }], ["inspect", { reviewerID: randomUUID() }],
      ["decide", { inspectionID: randomUUID(), decisionID: randomUUID(), verdict: "approved", expectedRevision: randomUUID() }],
      ["decide", { inspectionID: randomUUID(), decisionID: randomUUID(), verdict: "approved", accountID: randomUUID() }]]) {
      await json(await f.call(action, extra), 400);
    }
    assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
    assert.throws(() => avatarReviewInput("decide", { inspectionID: randomUUID(), decisionID: randomUUID(), verdict: "published" }));
  } finally { f.close(); }
});

test("owner can still withdraw while only moderation is enabled and old inspection then cannot decide", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true });
  try {
    const image = await f.edge("inspect"), body = decide(image); await image.arrayBuffer();
    const request = new Request("https://echoes.test.invalid/v1/community/avatar/clear", { method: "POST", headers: { "Content-Type": "application/json",
      Authorization: "Bearer " + f.signedIn.sessionToken, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify({ requestID: randomUUID(), expectedGeneration: f.pending.generation }) });
    Object.defineProperty(request, "cf", { value: { colo: "WAW" } });
    assert.equal((await json(await forwardGatewayRequest(request, f.env, { clock: f.clock }))).status, "none");
    await json(await f.edge("decide", body), 409);
  } finally { f.close(); }
});

test("account quota denial happens before body, scheduling, checkpoint and download", async () => {
  for (const inspection of [false, true]) {
    const f = await avatarReviewHTTPFixture(), held = stream();
    try {
      for (let i = 0; i < (inspection ? 10 : 30); i++) await f.limits.consumeAvatarReview(f.reviewer.accountID, { inspection });
      await json(await f.call(inspection ? "inspect" : "queue", {}, { rawBody: held.raw }), 429);
      assert.equal(held.pulled, false); assert.equal(held.cancelled, true); assert.equal(f.counts().scheduled, 0);
      assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
    } finally { held.close(); f.close(); }
  }
});

test("role loss and changed authenticated account during durable quota cannot consume the body", async () => {
  for (const mode of ["role", "identity"]) {
    const f = await avatarReviewHTTPFixture(), held = stream();
    try {
      const original = f.dependencies.limits.consumeAvatarReview;
      f.dependencies.limits.consumeAvatarReview = async (...args) => {
        await original(...args);
        if (mode === "role") f.operators.clear();
        else f.state.authorize = () => ({ accountID: f.signedIn.accountID });
      };
      await json(await f.call("inspect", {}, { rawBody: held.raw }), mode === "role" ? 403 : 401);
      assert.equal(held.pulled, false); assert.equal(held.cancelled, true); assert.equal(f.counts().verifies, 0);
    } finally { held.close(); f.close(); }
  }
});

test("strict headers reject encoding, large declarations, forged proof headers and bad bearer before body", async () => {
  for (const [headers, status] of [
    [{ "Content-Type": "image/jpeg" }, 415], [{ "Content-Encoding": "gzip" }, 415], [{ "Content-Length": "513" }, 413],
    [{ "X-Echoes-Avatar-Review": "forged" }, 400], [{ "X-Echoes-Avatar-Manifest": "forged" }, 400],
    [{ "X-Echoes-Avatar-Intent": "{}" }, 400], [{ Authorization: "Bearer malformed" }, 401],
  ]) {
    const f = await avatarReviewHTTPFixture(), held = stream();
    try {
      await json(await f.call("inspect", {}, { headers, rawBody: held.raw }), status);
      assert.equal(held.pulled, false); assert.equal(held.cancelled, true); assert.equal(f.counts().accountLimits, 0);
      assert.equal(f.counts().verifies, 0);
    } finally { held.close(); f.close(); }
  }
});

test("body framing, malformed UTF8, zero chunks and oversized content fail before checkpoint", async () => {
  for (const mode of ["utf8", "large", "zero", "length", "json", "fragments"]) {
    const f = await avatarReviewHTTPFixture();
    try {
      const rawBody = mode === "utf8" ? new Uint8Array([0xff]) : mode === "large" ? new Uint8Array(513) : mode === "json" ? "{PRIVATE-INPUT" : mode === "length" ? "{}" :
        new ReadableStream({ start(c) { if (mode === "zero") c.enqueue(new Uint8Array()); else for (let i = 0; i < 129; i++) c.enqueue(new Uint8Array([32])); c.close(); } });
      await json(await f.call("queue", {}, { rawBody, ...(mode === "length" ? { headers: { "Content-Length": "3" } } : {}) }), mode === "large" ? 413 : 400);
      assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
    } finally { f.close(); }
  }
});

test("input timeout cancels an unread stream without scheduling or checkpoint", async () => {
  const f = await avatarReviewHTTPFixture({ inputTimeoutMilliseconds: 30 }), held = stream();
  try {
    await json(await f.call("queue", {}, { rawBody: held.raw }), 503);
    assert.equal(held.cancelled, true); assert.equal(f.counts().scheduled, 0); assert.equal(f.counts().verifies, 0);
  } finally { held.close(); f.close(); }
});

test("authority admission remains occupied when a timed-out durable budget ignores cancellation", async () => {
  const f = await avatarReviewHTTPFixture({ reviewTimeoutMilliseconds: 200 }); let release, entered;
  const held = new Promise(r => { release = r; }), arrived = new Promise(r => { entered = r; });
  try {
    const original = f.dependencies.limits.consume; let once = true;
    f.dependencies.limits.consume = async (...args) => { if (once) { once = false; entered(); await held; } return original(...args); };
    const first = f.call("queue"); await arrived; await json(await first, 503);
    assert.equal((await json(await f.call("queue"), 429)).error, "AVATAR_REVIEW_CAPACITY");
    release(); let resumed = false;
    for (let i = 0; i < 100; i++) {
      const response = await f.call("queue");
      if (response.status === 200) { await response.arrayBuffer(); resumed = true; break; }
      await json(response, 429); await new Promise(r => setTimeout(r, 2));
    }
    assert.equal(resumed, true); assert.equal(f.downloads.length, 0);
  } finally { release(); f.close(); }
});

test("edge admission survives an aborted caller until ignored authority IO really returns", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true }); let release, entered;
  const held = new Promise(r => { release = r; }), arrived = new Promise(r => { entered = r; });
  const original = f.env.COMMUNITY_AUTHORITY.get, controller = new AbortController(); let first = true;
  try {
    f.env.COMMUNITY_AUTHORITY.get = id => { const target = original(id); return { async fetch(request) {
      if (first) { first = false; entered(); await held; return Response.json({ protocolVersion: 1, schemaVersion: 1, items: [] }, { headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }); }
      return target.fetch(request);
    } }; };
    const operation = f.edge("queue", {}, { signal: controller.signal }); await arrived; controller.abort();
    await json(await operation, 503);
    assert.equal((await json(await f.edge("queue"), 429)).error, "AVATAR_REVIEW_CAPACITY");
    release(); let resumed = false;
    for (let i = 0; i < 100; i++) {
      const response = await f.edge("queue");
      if (response.status === 200) { await response.arrayBuffer(); resumed = true; break; }
      await json(response, 429); await new Promise(r => setTimeout(r, 2));
    }
    assert.equal(resumed, true);
  } finally { release(); f.close(); }
});

test("disabled edge rejects and cancels the request before authority or client-controlled identity headers", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true }), held = stream();
  try {
    f.env.AVATAR_REVIEW_ENABLED = "0";
    await json(await f.edge("inspect", {}, { rawBody: held.raw }), 503);
    assert.equal(held.pulled, false); assert.equal(held.cancelled, true); assert.equal(f.forwarded.length, 0);
    f.env.AVATAR_REVIEW_ENABLED = "1";
    const result = await json(await f.edge("queue", {}, { token: f.signedIn.sessionToken, headers: {
      "X-Echoes-Reviewer-ID": f.reviewer.accountID, "X-Echoes-Request-Budget": "forged", "X-Forwarded-For": "203.0.113.1",
    } }), 403);
    assert.equal(result.error, "AVATAR_REVIEW_SCOPE");
    const request = f.forwarded[0]; assert.equal(request.headers.has("X-Echoes-Reviewer-ID"), false);
    assert.equal(request.headers.has("X-Forwarded-For"), false); assert.notEqual(request.headers.get("X-Echoes-Request-Budget"), "forged");
  } finally { held.close(); f.close(); }
});

test("runtime revocation of role configuration after authority response denies edge publication", async () => {
  const f = await avatarReviewHTTPFixture({ runtime: true });
  try {
    const original = f.env.COMMUNITY_AUTHORITY.get;
    f.env.COMMUNITY_AUTHORITY.get = id => { const target = original(id); return { async fetch(request) {
      const response = await target.fetch(request); f.env.AVATAR_REVIEWER_IDS_JSON = JSON.stringify([randomUUID()]); return response;
    } }; };
    await json(await f.edge("inspect"), 503); assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("operator transport keeps HTTPS, native origin and fixed method boundaries", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    for (const [url, options, status] of [
      ["http://echoes.test/v1/moderation/avatar/queue", {}, 400], ["https://echoes.test/v1/moderation/avatar/queue?role=admin", {}, 400],
      ["https://echoes.test/v1/moderation/avatar/queue", { method: "GET" }, 405],
      ["https://echoes.test/v1/moderation/avatar/queue", { headers: { Origin: "https://evil.invalid" } }, 403],
      ["https://echoes.test/v1/community/avatar/review", {}, 404],
    ]) {
      const request = new Request(url, { method: options.method ?? "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + f.reviewer.sessionToken, ...options.headers },
        ...(options.method === "GET" ? {} : { body: "{}" }) });
      await json(await f.authority.handle(request, "e".repeat(64)), status);
    }
    assert.equal(f.counts().budgets, 0); assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("closed output validators reject private fields, duplicate accounts and mismatched decision identities", () => {
  const accountID = randomUUID(), requestID = randomUUID(), item = { accountID, requestID, versionID: randomUUID(), generation: 1, reviewRevision: randomUUID() };
  for (const value of [{ schemaVersion: 1, items: [item, item] }, { schemaVersion: 1, items: [{ ...item, providerURL: "https://PRIVATE.invalid" }] },
    { schemaVersion: 1, items: Array(21).fill(item) }, { schemaVersion: 1, items: [{ ...item, generation: 0 }] }]) assert.throws(() => avatarReviewResult("queue", value));
  const result = { schemaVersion: 1, inspectionID: randomUUID(), accountID, requestID, decisionID: randomUUID(), revision: randomUUID(), verdict: "approved" };
  assert.throws(() => avatarReviewResult("decide", result, { ...result, decisionID: randomUUID() }));
  assert.throws(() => avatarReviewResult("decide", { ...result, receipt: "PRIVATE" }));
});

test("authority rejects asynchronous or private-field finalizers without leaking their data", async () => {
  for (const mode of ["async", "private", "non-function"]) {
    const fake = mode === "non-function" ? () => ({}) : mode === "async" ? () => async () => ({ schemaVersion: 1, items: [] }) : () => () => ({ schemaVersion: 1, items: [], PRIVATE: "do-not-expose" });
    const f = await avatarReviewHTTPFixture({ avatarReview: { prepareQueue: async () => fake() } });
    try {
      const body = await json(await f.call("queue"), 503); assert.equal(body.error, "AVATAR_REVIEW_RESPONSE");
      assert.doesNotMatch(JSON.stringify(body), /PRIVATE|do-not-expose/);
    } finally { f.close(); }
  }
});

test("edge validates exact error status/code and never forwards private headers or fields", async () => {
  const deadline = avatarReviewDeadline(undefined, 1000);
  try {
    for (const [body, status, headers] of [
      [{ protocolVersion: 1, error: "AVATAR_REVIEW_SCOPE" }, 400, {}],
      [{ protocolVersion: 1, error: "PRIVATE_URL" }, 503, {}],
      [{ protocolVersion: 1, error: "AVATAR_REVIEW_UNAVAILABLE", PRIVATE: "secret" }, 503, {}],
      [{ protocolVersion: 1, schemaVersion: 1, items: [] }, 200, { "Cache-Control": "public" }],
    ]) await assert.rejects(() => avatarReviewEdgeResponse(Response.json(body, { status, headers: {
      "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers,
    } }), "queue", deadline), { code: "AVATAR_REVIEW_RESPONSE" });
    const result = await avatarReviewEdgeResponse(Response.json({ protocolVersion: 1, error: "AVATAR_REVIEW_SCOPE" }, { status: 403, headers: {
      "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Set-Cookie": "PRIVATE", "X-Internal": "PRIVATE",
    } }), "queue", deadline);
    assert.equal(result.status, 403); assert.equal(result.headers.has("Set-Cookie"), false); assert.equal(result.headers.has("X-Internal"), false);
  } finally { deadline.close(); }
});

test("global and IP heavy limits deny before headers, account quota, body and checkpoint", async () => {
  const f = await avatarReviewHTTPFixture(), held = stream();
  try {
    for (let i = 0; i < 12; i++) await f.limits.consume("d".repeat(64), { heavy: true });
    await json(await f.call("inspect", {}, { rawBody: held.raw }), 429);
    assert.equal(held.pulled, false); assert.equal(held.cancelled, true);
    assert.equal(f.counts().accountLimits, 0); assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
  } finally { held.close(); f.close(); }
});

test("authority correlates binary proof to the requested owner and validates expiry, variant, exact fields and hash", async () => {
  const f = await avatarReviewHTTPFixture();
  try {
    const original = await f.inspect(), bytes = new Uint8Array(await original.arrayBuffer()), metadata = JSON.parse(original.headers.get(avatarReviewHeader));
    const manifest = JSON.parse(original.headers.get("x-echoes-avatar-manifest"));
    for (const mode of ["owner", "request", "expired", "future", "extra", "header-size", "variant", "hash", "length"]) {
      const headers = new Headers(original.headers), proof = { ...metadata }, picture = { ...manifest }; let data = bytes.slice();
      if (mode === "owner") picture.ownerID = randomUUID();
      if (mode === "request") proof.requestID = randomUUID();
      if (mode === "expired") proof.expiresAt = f.clock();
      if (mode === "future") proof.expiresAt = f.clock() + 90001;
      if (mode === "extra") proof.PRIVATE = "do-not-forward";
      if (mode === "variant") picture.variant = "thumbnail";
      if (mode === "hash") data[0] ^= 1;
      if (mode === "length") data = new Uint8Array(bytes.length + 1);
      headers.set(avatarReviewHeader, mode === "header-size" ? "x".repeat(1025) : JSON.stringify(proof));
      headers.set("x-echoes-avatar-manifest", JSON.stringify(picture));
      f.dependencies.avatarReview.prepareInspection = async () => () => new Response(data, { headers });
      const body = await json(await f.call("inspect"), 503); assert.equal(body.error, "AVATAR_REVIEW_RESPONSE");
      assert.doesNotMatch(JSON.stringify(body), /PRIVATE|do-not-forward/);
    }
    f.dependencies.avatarReview.prepareInspection = async () => () => new Response(bytes.slice(), { headers: { ...Object.fromEntries(original.headers), "Set-Cookie": "PRIVATE" } });
    const valid = await f.call("inspect"); assert.equal(valid.status, 200); assert.equal(valid.headers.has("Set-Cookie"), false);
    assert.equal(digest(new Uint8Array(await valid.arrayBuffer())), manifest.sha256);
  } finally { f.close(); }
});
