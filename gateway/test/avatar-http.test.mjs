import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID, createHash } from "node:crypto";
import { avatarHTTPFixture } from "./support/avatar-http-fixture.mjs";
import { avatarReadBody, avatarHTTPManifest, avatarDownloadHosts, avatarHTTPDeadline, avatarEdgeResponse, avatarEdgeErrorResponse } from "../src/gateway-avatar-http.mjs";
import { AvatarReadError, avatarManifestHeader } from "../src/cloudkit-avatar-reader.mjs";
import { activeGatewayConfiguration, createGatewayRuntime } from "../src/gateway-runtime.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";
import { digest } from "../src/public-record-schema.mjs";
const code = value => error => error?.code === value && !error.message.includes("PRIVATE-") && error.cause === undefined;
const budget = () => createHash("sha256").update(randomUUID()).digest("hex");

async function jpeg(response, status = 200) {
  assert.equal(response.status, status);
  assert.equal(response.headers.get("Cache-Control"), "private, no-store");
  const manifest = avatarHTTPManifest(response.headers.get(avatarManifestHeader));
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (status === 200) { assert.equal(digest(bytes), manifest.sha256); assert.equal(response.headers.get("Content-Length"), String(bytes.length)); }
  else { assert.equal(bytes.length, 0); assert.equal(response.headers.get("Content-Length"), null); }
  return manifest;
}

test("avatar HTTP handler returns exact JPEG and freshly authorized empty 204 through the last checkpoint", async () => {
  const f = await avatarHTTPFixture();
  try {
    const manifest = await jpeg(await f.call()); assert.equal(f.downloads.length, 1);
    await jpeg(await f.call({ knownSHA256: manifest.sha256 }), 204); assert.equal(f.downloads.length, 1);
    assert.deepEqual(f.counts(), { requestCount: 2, verifies: 2, reads: 2, accountLimits: 2, runtimeDownloads: 0 });
  } finally { f.close(); }
});

test("concrete runtime and fixed edge carry both avatar variants and private 204 without leaking provider headers", async () => {
  const f = await avatarHTTPFixture({ runtime: true });
  try {
    for (const variant of ["image", "thumbnail"]) {
      const manifest = await jpeg(await f.edge({ variant }));
      await jpeg(await f.edge({ variant, knownSHA256: manifest.sha256 }), 204);
    }
    assert.equal(f.counts().runtimeDownloads, 2);
  } finally { f.close(); }
});

test("avatar read is separately disabled before consuming any body, budget or provider IO", async () => {
  const f = await avatarHTTPFixture();
  try {
    f.setFeature(false);
    assert.equal((await f.call()).status, 503); assert.equal(f.counts().requestCount, 0);
    assert.equal(f.counts().verifies, 0); assert.equal(f.counts().reads, 0);
    f.env.AVATAR_READ_ENABLED = "0";
    assert.equal((await f.edge()).status, 503); assert.equal(f.counts().requestCount, 0);
    assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("activation validates flag dependencies and a closed deployment-only exact-host list", async () => {
  const f = await avatarHTTPFixture();
  try {
    for (const changes of [{ AVATAR_READ_ENABLED: "yes" }, { COMMUNITY_ENABLED: "0" }, { PUBLIC_RECORDS_ENABLED: "0" },
      { AVATAR_DOWNLOAD_HOSTS_JSON: "[]" }, { AVATAR_DOWNLOAD_HOSTS_JSON: '"icloud.com"' },
      { AVATAR_DOWNLOAD_HOSTS_JSON: '["icloud.com"]' }, { AVATAR_DOWNLOAD_HOSTS_JSON: '["x.icloud.com","x.icloud.com"]' },
      { AVATAR_DOWNLOAD_HOSTS_JSON: '["evil.example.invalid"]' }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...changes }, f.clock()), null);
    assert.deepEqual(avatarDownloadHosts('["a.icloud-content.com"]'), ["a.icloud-content.com"]);
    f.env.AVATAR_READ_ENABLED = "0"; delete f.env.AVATAR_DOWNLOAD_HOSTS_JSON;
    assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarReadEnabled, false);
  } finally { f.close(); }
});

test("closed avatar JSON never accepts a client URL, access token, server budget or invalid selection", async () => {
  const f = await avatarHTTPFixture();
  try {
    for (const changes of [{ url: "https://private.invalid" }, { accessToken: "PRIVATE-TOKEN" }, { serverBudgetHash: budget() },
      { ownerID: "not-a-uuid" }, { versionID: null }, { variant: "original" }, { knownSHA256: "A".repeat(64) },
      { coordinate: { latitude: 91, longitude: 0 } }, { coordinate: { latitude: 1, longitude: 0, extra: true } }]) {
      const response = await f.call(changes, { budget: budget() }); assert.equal(response.status, 400);
      assert.equal((await response.json()).error, "AVATAR_READ_INPUT");
    }
    assert.equal(f.counts().verifies, 0); assert.equal(f.counts().reads, 0);
    const value = f.body(); const parsed = avatarReadBody(value); value.coordinate.latitude = 0;
    assert.notEqual(parsed.coordinate.latitude, 0); assert.ok(Object.isFrozen(parsed)); assert.ok(Object.isFrozen(parsed.coordinate));
  } finally { f.close(); }
});

test("malformed session, media, declared length and oversized streamed body stop before checkpoint", async () => {
  const f = await avatarHTTPFixture();
  try {
    for (const token of ["x", randomUUID() + "." + "!".repeat(43)]) assert.equal((await f.call({}, { token, budget: budget() })).status, 401);
    assert.equal((await f.call({}, { headers: { "Content-Type": "image/jpeg" }, budget: budget() })).status, 415);
    assert.equal((await f.call({}, { headers: { "Content-Encoding": "gzip" }, budget: budget() })).status, 415);
    assert.equal((await f.call({}, { headers: { "Content-Length": "2049" }, budget: budget() })).status, 413);
    assert.equal((await f.call({}, { rawBody: " ".repeat(2049), budget: budget() })).status, 413);
    assert.equal((await f.call({}, { headers: { "Content-Length": "1" }, budget: budget() })).status, 400);
    assert.equal(f.counts().verifies, 0); assert.equal(f.counts().reads, 0);
  } finally { f.close(); }
});

test("zero-length and excessive tiny input chunks cannot starve the body timeout", async () => {
  const f = await avatarHTTPFixture();
  try {
    for (const empty of [true, false]) {
      let cancelled = false;
      const stream = new ReadableStream({ pull(c) { c.enqueue(empty ? new Uint8Array() : new Uint8Array([32])); }, cancel() { cancelled = true; } });
      const response = await f.call({}, { rawBody: stream, budget: budget() });
      assert.equal(response.status, 400); assert.equal(cancelled, true);
    }
    assert.equal(f.counts().verifies, 0);
  } finally { f.close(); }
});

test("per-account avatar limits survive reconstruction and IP rotation, with a separate full-image ceiling", async () => {
  const f = await avatarHTTPFixture();
  try {
    let hash;
    for (let i = 0; i < 12; i++) hash = (await jpeg(await f.call(hash ? { knownSHA256: hash } : {}, { budget: budget() }), hash ? 204 : 200)).sha256;
    const before = f.counts().verifies;
    const denied = await f.call({ knownSHA256: hash }, { budget: budget() }); assert.equal(denied.status, 429);
    assert.equal(f.counts().verifies, before);
    await assert.rejects(new GatewayLimits(f.storage, { clock: f.clock }).consumeAvatarRead(f.viewer.accountID, { variant: "thumbnail" }), code("RATE_LIMITED"));
    const rows = f.db.prepare("SELECT key_hash FROM gateway_windows_v1 WHERE kind='avatar-account'").all();
    assert.ok(rows.every(r => /^[a-f0-9]{64}$/.test(r.key_hash) && r.key_hash !== f.viewer.accountID));
    f.advance(60000);
    for (let i = 0; i < 4; i++) assert.equal((await f.call({ variant: "image" }, { budget: budget() })).status, 200);
    assert.equal((await f.call({ variant: "image" }, { budget: budget() })).status, 429);
  } finally { f.close(); }
});

test("revoked publication and peer block deny cached-avatar revalidation before any asset GET", async () => {
  const f = await avatarHTTPFixture();
  try {
    const manifest = await jpeg(await f.call()); const before = f.downloads.length;
    await f.callCommunity(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: true, generation: 0 });
    const denied = await f.call({ knownSHA256: manifest.sha256 }); assert.equal(denied.status, 404);
    assert.equal((await denied.json()).error, "AVATAR_READ_NOT_FOUND"); assert.equal(f.downloads.length, before);
  } finally { f.close(); }
});

test("final HTTP feature check cancels a prepared JPEG and frees its slot after the last checkpoint", async () => {
  const f = await avatarHTTPFixture();
  try {
    f.afterLastAdvance(() => f.setFeature(false));
    const stopped = await f.call(); assert.equal(stopped.status, 503);
    assert.equal(stopped.headers.has(avatarManifestHeader), false);
    f.afterLastAdvance(undefined); f.setFeature(true);
    await jpeg(await f.call());
  } finally { f.close(); }
});

test("own approved photo remains readable without GPS or map presence", async () => {
  const f = await avatarHTTPFixture();
  try {
    const body = f.body(); delete body.coordinate;
    await jpeg(await f.call({}, { rawBody: JSON.stringify(body), token: f.signedIn.sessionToken }));
  } finally { f.close(); }
});

test("host configuration drift or expiry closes an already created concrete runtime", async () => {
  const f = await avatarHTTPFixture({ runtime: true });
  try {
    await jpeg(await f.call());
    f.env.AVATAR_DOWNLOAD_HOSTS_JSON = '["other.icloud-content.com"]';
    const denied = await f.call(); assert.equal(denied.status, 503);
    f.env.AVATAR_DOWNLOAD_HOSTS_JSON = '["synthetic-avatar.icloud-content.com"]';
    f.advance(3600001); assert.equal((await f.call()).status, 503);
  } finally { f.close(); }
});

test("avatar HTTP admits only four pending bodies and releases slots after input finishes", async () => {
  const f = await avatarHTTPFixture({ inputTimeoutMilliseconds: 500 }); const controllers = [];
  try {
    const pending = Array.from({ length: 4 }, () => {
      const stream = new ReadableStream({ start(c) { controllers.push(c); c.enqueue(new TextEncoder().encode(JSON.stringify(f.body()))); } });
      return f.call({}, { rawBody: stream, budget: budget() });
    });
    for (let i = 0; i < 100 && f.counts().requestCount < 4; i++) await new Promise(r => setTimeout(r, 1));
    const rejected = await f.call({}, { budget: budget() }); assert.equal(rejected.status, 429);
    assert.equal((await rejected.json()).error, "AVATAR_READ_LIMIT"); assert.equal(f.counts().requestCount, 4);
    for (const c of controllers) c.close();
    const responses = await Promise.all(pending); assert.ok(responses.every(r => [200, 503].includes(r.status)));
    await jpeg(await f.call({}, { budget: budget() }));
  } finally { for (const c of controllers) try { c.close(); } catch {} f.close(); }
});

test("input cancellation and absolute avatar deadline stop before provider IO and release admission", async () => {
  const f = await avatarHTTPFixture({ avatarTimeoutMilliseconds: 10 });
  try {
    const controller = new AbortController(); let cancelled = false;
    const stream = new ReadableStream({ pull() { return new Promise(() => {}); }, cancel() { cancelled = true; } });
    const work = f.call({}, { rawBody: stream, signal: controller.signal }); controller.abort();
    assert.ok([408, 503].includes((await work).status));
    const timeout = await f.call({}, { rawBody: new ReadableStream({ pull() { return new Promise(() => {}); } }), budget: budget() });
    assert.equal(timeout.status, 503); assert.equal(f.counts().verifies, 0); assert.equal(f.counts().reads, 0);
    // No positive read under a 10 ms total deadline is assumed. A fresh valid request must be admitted.
    const after = await f.call({}, { budget: budget() }); assert.notEqual(after.status, 429);
    assert.equal(cancelled, true);
  } finally { f.close(); }
});

test("non-Response or asynchronous finalizers cannot move the authority guard past an await", async () => {
  for (const finalize of [() => ({ private: "PRIVATE-RECEIPT" }), async () => new Response("PRIVATE-URL")]) {
    const f = await avatarHTTPFixture({ avatarReader: { async prepare() { return finalize; } } });
    try {
      const response = await f.call(); assert.equal(response.status, 503);
      assert.deepEqual(await response.json(), { protocolVersion: 1, error: "AVATAR_READ_RESPONSE" });
    } finally { f.close(); }
  }
});

test("public edge rejects browser origins before private authority and strips unapproved response headers", async () => {
  const f = await avatarHTTPFixture({ runtime: true });
  try {
    assert.equal((await f.edge({}, { headers: { Origin: "https://hostile.invalid" } })).status, 403);
    const original = f.env.COMMUNITY_AUTHORITY.get;
    f.env.COMMUNITY_AUTHORITY.get = id => ({ async fetch(request) {
      const response = await original(id).fetch(request);
      response.headers.set("Set-Cookie", "PRIVATE-COOKIE"); response.headers.set("Location", "https://PRIVATE-URL.invalid");
      response.headers.set("X-Private-Receipt", "PRIVATE-RECEIPT"); return response;
    } });
    const response = await f.edge(); await jpeg(response);
    for (const name of ["Set-Cookie", "Location", "X-Private-Receipt", "X-Echoes-Request-Budget"]) assert.equal(response.headers.get(name), null);
  } finally { f.close(); }
});

test("edge binary validation rejects wrong headers, malformed metadata, corrupt bytes and oversized streams", async () => {
  const f = await avatarHTTPFixture();
  try {
    const original = await f.call(), bytes = new Uint8Array(await original.arrayBuffer()), headers = Object.fromEntries(original.headers);
    const bad = [];
    for (const changed of [{ "content-type": "application/json" }, { "content-encoding": "gzip" }, { "content-range": "bytes 0-1/9" },
      { "cache-control": "public, max-age=600" }, { "content-length": "999999" }, { [avatarManifestHeader.toLowerCase()]: "{}" }]) {
      bad.push(new Response(bytes, { headers: { ...headers, ...changed } }));
    }
    const corrupt = bytes.slice(); corrupt[corrupt.length / 2 | 0] ^= 1;
    bad.push(new Response(corrupt, { headers })); bad.push(new Response(new Uint8Array(bytes.length + 1), { headers }));
    bad.push(new Response(bytes, { status: 206, headers }));
    for (const response of bad) {
      const deadline = avatarHTTPDeadline(undefined, 1000);
      try { await assert.rejects(avatarEdgeResponse(response, deadline), code("AVATAR_READ_RESPONSE")); }
      finally { deadline.close(); }
    }
  } finally { f.close(); }
});

test("edge pending stream is bounded by cancellation and subsequent valid response can use the slot", async () => {
  const f = await avatarHTTPFixture();
  try {
    const source = await f.call(), bytes = new Uint8Array(await source.arrayBuffer()), headers = Object.fromEntries(source.headers);
    let cancelled = false;
    const stream = new ReadableStream({ pull() { return new Promise(() => {}); }, cancel() { cancelled = true; } });
    const controller = new AbortController(), deadline = avatarHTTPDeadline(controller.signal, 1000);
    const operation = avatarEdgeResponse(new Response(stream, { headers }), deadline);
    controller.abort(); await assert.rejects(operation, code("AVATAR_READ_UNAVAILABLE")); deadline.close();
    assert.equal(cancelled, true);
    const next = avatarHTTPDeadline(undefined, 1000);
    try { await jpeg(await avatarEdgeResponse(new Response(bytes, { headers }), next)); } finally { next.close(); }
  } finally { f.close(); }
});

test("edge refuses over 128 binary chunks and a false empty-204 contract without buffering unbounded data", async () => {
  const f = await avatarHTTPFixture();
  try {
    const source = await f.call(), bytes = new Uint8Array(await source.arrayBuffer()), headers = Object.fromEntries(source.headers);
    for (const empty of [true, false]) {
      const stream = new ReadableStream({ pull(c) { c.enqueue(empty ? new Uint8Array() : new Uint8Array([0])); } });
      const deadline = avatarHTTPDeadline(undefined, 1000);
      try { await assert.rejects(avatarEdgeResponse(new Response(stream, { headers }), deadline), code("AVATAR_READ_RESPONSE")); } finally { deadline.close(); }
    }
    delete headers["content-length"]; headers["content-type"] = "image/jpeg";
    const deadline = avatarHTTPDeadline(undefined, 1000);
    try { await assert.rejects(avatarEdgeResponse(new Response(null, { status: 204, headers }), deadline), code("AVATAR_READ_RESPONSE")); } finally { deadline.close(); }
    assert.ok(bytes.length > 128);
  } finally { f.close(); }
});

test("persistent request/day and account quotas are consumed before any checkpoint even for cache revalidation", async () => {
  const f = await avatarHTTPFixture();
  try {
    await f.call(); const day = Math.floor(f.clock() / 86400000);
    f.db.prepare("UPDATE gateway_daily_v1 SET heavy=300 WHERE day=?").run(day);
    const before = f.counts().verifies;
    const response = await f.call({ knownSHA256: "0".repeat(64) }, { budget: budget() });
    assert.equal(response.status, 429); assert.equal(f.counts().verifies, before);
    assert.equal(f.counts().reads, 1);
  } finally { f.close(); }
});

test("edge checks feature state again after its bounded body copy, before releasing public pixels", async () => {
  const f = await avatarHTTPFixture({ runtime: true }); let release;
  try {
    const original = f.env.COMMUNITY_AUTHORITY.get;
    f.env.COMMUNITY_AUTHORITY.get = id => ({ async fetch(request) {
      const response = await original(id).fetch(request), headers = Object.fromEntries(response.headers);
      const bytes = new Uint8Array(await response.arrayBuffer());
      const stream = new ReadableStream({ start(c) { c.enqueue(bytes.slice(0, 1)); }, pull(c) {
        return new Promise(resolve => { release = () => { c.enqueue(bytes.slice(1)); c.close(); resolve(); }; });
      } });
      return new Response(stream, { headers });
    } });
    const operation = f.edge();
    for (let i = 0; i < 1000 && !release; i++) await new Promise(resolve => setTimeout(resolve, 1));
    assert.equal(typeof release, "function");
    f.env.AVATAR_READ_ENABLED = "0"; release();
    const response = await operation; assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { protocolVersion: 1, error: "FEATURE_DISABLED" });
    assert.equal(response.headers.has(avatarManifestHeader), false);
  } finally { try { release?.(); } catch {} f.close(); }
});

test("edge has four bounded copy slots and releases them when streams settle", async () => {
  const f = await avatarHTTPFixture(); const controllers = [], deadlines = [];
  try {
    const source = await f.call(), bytes = new Uint8Array(await source.arrayBuffer()), headers = Object.fromEntries(source.headers);
    const pending = Array.from({ length: 4 }, () => {
      const deadline = avatarHTTPDeadline(undefined, 1000); deadlines.push(deadline);
      const stream = new ReadableStream({ start(c) { controllers.push(c); c.enqueue(bytes); } });
      return avatarEdgeResponse(new Response(stream, { headers }), deadline);
    });
    const denied = avatarHTTPDeadline(undefined, 1000); deadlines.push(denied);
    await assert.rejects(avatarEdgeResponse(new Response(bytes, { headers }), denied), code("AVATAR_READ_LIMIT"));
    for (const c of controllers) c.close();
    for (const response of await Promise.all(pending)) await jpeg(response);
    const next = avatarHTTPDeadline(undefined, 1000); deadlines.push(next);
    await jpeg(await avatarEdgeResponse(new Response(bytes, { headers }), next));
  } finally { for (const deadline of deadlines) deadline.close(); for (const c of controllers) try { c.close(); } catch {} f.close(); }
});

test("feature disable during durable account admission prevents the first checkpoint RPC", async () => {
  const f = await avatarHTTPFixture();
  try {
    const consume = f.dependencies.limits.consumeAvatarRead;
    f.dependencies.limits.consumeAvatarRead = async (...args) => { await consume(...args); f.setFeature(false); };
    const response = await f.call(); assert.equal(response.status, 503);
    assert.equal(f.counts().accountLimits, 1); assert.equal(f.counts().verifies, 0); assert.equal(f.counts().reads, 0);
  } finally { f.close(); }
});

test("edge owns the completed error body before request cleanup aborts its upstream signal", async () => {
  const f = await avatarHTTPFixture();
  try {
    let aborted = false;
    f.env.COMMUNITY_AUTHORITY.get = () => ({ fetch(request) {
      const bytes = new TextEncoder().encode(JSON.stringify({ protocolVersion: 1, error: "INVALID_SESSION" }));
      const stream = new ReadableStream({ start(c) {
        request.signal.addEventListener("abort", () => { aborted = true; try { c.error(new Error("PRIVATE-ABORTED-STREAM")); } catch {} }, { once: true });
        c.enqueue(bytes); queueMicrotask(() => c.close());
      } });
      return new Response(stream, { status: 401, headers: { "Content-Type": "application/json", "Set-Cookie": "PRIVATE-COOKIE" } });
    } });
    const response = await f.edge(); assert.equal(aborted, true); assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { protocolVersion: 1, error: "INVALID_SESSION" });
    assert.equal(response.headers.has("Set-Cookie"), false);
  } finally { f.close(); }
});

test("edge rejects oversized, malformed or private diagnostic error JSON before returning it", async () => {
  for (const response of [
    new Response(" ".repeat(32769), { status: 503, headers: { "Content-Type": "application/json" } }),
    Response.json({ protocolVersion: 1, error: "INVALID_SESSION", private: "PRIVATE-TOKEN" }, { status: 401 }),
    Response.json({ protocolVersion: 1, error: "PRIVATE_SECRET_VALUE" }, { status: 503 }),
    Response.json({ protocolVersion: 2, error: "INVALID_SESSION" }, { status: 401 }),
    new Response("PRIVATE-HTML", { status: 503, headers: { "Content-Type": "text/html" } }),
    Response.json({ protocolVersion: 1, error: "INVALID_SESSION" }, { status: 202 }),
  ]) {
    const deadline = avatarHTTPDeadline(undefined, 1000);
    try { await assert.rejects(avatarEdgeErrorResponse(response, deadline), code("AVATAR_READ_RESPONSE")); }
    finally { deadline.close(); }
  }
});
