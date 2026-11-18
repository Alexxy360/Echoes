import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID, createHash } from "node:crypto";
import { avatarOwnerPreviewFixture } from "./support/avatar-owner-preview-fixture.mjs";
import { CloudKitAvatarOwnerPreview } from "../src/cloudkit-avatar-owner-preview.mjs";
import { avatarOwnerPreviewInput, avatarOwnerPreviewResponse, avatarOwnerPreviewEdgeResponse, avatarSelectionHeader } from "../src/avatar-owner-preview-http.mjs";
import { avatarHTTPManifest, avatarHTTPDeadline } from "../src/gateway-avatar-http.mjs";
import { avatarManifestHeader } from "../src/cloudkit-avatar-reader.mjs";
import { activeGatewayConfiguration, forwardGatewayRequest } from "../src/gateway-runtime.mjs";
import { createGatewayHTTPHandler } from "../src/gateway-http.mjs";
import { digest } from "../src/public-record-schema.mjs";
const budget = () => createHash("sha256").update(randomUUID()).digest("hex");
const code = expected => e => e?.code === expected && e.cause === undefined && !e.message.includes("SYNTHETIC");
const immediate = () => new Promise(resolve => setImmediate(resolve));
async function image(response, f) {
  assert.equal(response.status, 200, response.status === 200 ? undefined : await response.text());
  const manifest = avatarHTTPManifest(response.headers.get(avatarManifestHeader));
  assert.equal(manifest.ownerID, f.signedIn.accountID); assert.equal(manifest.versionID, f.current.versionID); assert.equal(manifest.variant, "image");
  assert.deepEqual(JSON.parse(response.headers.get(avatarSelectionHeader)), { schemaVersion: 1, ...f.body() });
  const bytes = new Uint8Array(await response.arrayBuffer()); assert.equal(digest(bytes), manifest.sha256);
  assert.equal(response.headers.get("Content-Length"), String(bytes.length));
  assert.deepEqual([...response.headers.keys()].sort(), ["cache-control", "content-length", "content-type", "x-content-type-options", "x-echoes-avatar-manifest", "x-echoes-avatar-selection"]);
  assert.equal(response.headers.get("Cache-Control"), "private, no-store");
  return { manifest, bytes };
}

test("owner preview reads approved ready=0 JPEG without GPS, pointer, moderator or publication", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    const pointer = f.registry.owned(f.signedIn.accountID, "avatarprofile", "singleton");
    assert.ok(pointer); assert.equal(f.model.records.delete(pointer.recordName), true);
    const before = f.policy.snapshot(f.signedIn.accountID), records = f.model.records.size;
    await image(await f.call(), f);
    assert.deepEqual(f.policy.snapshot(f.signedIn.accountID), before); assert.equal(f.model.records.size, records);
    assert.equal(f.downloads.length, 1); assert.deepEqual(f.counts(), { prepares: 1, finalChecks: 1, verifies: 1, accounts: 1, budgets: 1 });
    const final = await f.preview.prepare(f.selection()); const response = final();
    assert.throws(() => final(), code("AVATAR_READ_UNAVAILABLE")); final.validate(); await response.body.cancel();
  } finally { f.close(); }
});

test("concrete owner-preview runtime and fixed edge preserve exact selection and omit all provider authority", async () => {
  const f = await avatarOwnerPreviewFixture({ runtime: true });
  try {
    await image(await f.edge(), f); assert.equal(f.forwarded.length, 1);
    assert.equal((await f.edge({}, { token: f.viewer.sessionToken, budget: budget() })).status, 404);
    const clear = new Request("https://echoes-authority.internal/v1/community/avatar/clear", { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + f.signedIn.sessionToken },
      body: JSON.stringify({ requestID: randomUUID(), expectedGeneration: f.current.generation }) });
    assert.equal((await f.authority.handle(clear, budget())).status, 200); // Withdrawal remains usable when only preview is enabled.
    assert.equal((await f.edge()).status, 404);
  } finally { f.close(); }
});

test("owner preview accepts a closed exact approved tuple and no owner, URL, GPS, hash or consent", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    for (const extra of [{ ownerID: f.signedIn.accountID }, { accountID: f.signedIn.accountID }, { coordinate: f.coordinate },
      { url: "https://synthetic-private.invalid" }, { knownSHA256: "a".repeat(64) }, { consentVersion: 1 },
      { reviewRevision: null }, { generation: 0 }, { generation: Number.MAX_SAFE_INTEGER }, { requestID: "UPPER-INVALID" }]) {
      assert.throws(() => avatarOwnerPreviewInput(f.body(extra)), code("AVATAR_READ_INPUT"));
    }
    for (const key of Object.keys(f.body())) { const v = f.body(); delete v[key]; assert.throws(() => avatarOwnerPreviewInput(v), code("AVATAR_READ_INPUT")); }
    for (const extra of [{ ownerID: f.signedIn.accountID }, { consentVersion: 1 }, { reviewRevision: null }]) assert.equal((await f.call(extra, { budget: budget() })).status, 400);
    assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
    assert.ok(Object.isFrozen(avatarOwnerPreviewInput(f.body())));
  } finally { f.close(); }
});

test("owner preview never lets another native account select the author's staged photo", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    assert.equal((await f.call({}, { token: f.viewer.sessionToken })).status, 404);
    assert.equal(f.downloads.length, 0);
    for (const key of ["requestID", "versionID", "reviewRevision"]) assert.equal((await f.call({ [key]: randomUUID() }, { budget: budget() })).status, 404);
    assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("preview activation is separate, default closed, and validates exact hosts and dependencies", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    for (const changes of [{ AVATAR_OWNER_PREVIEW_ENABLED: "yes" }, { COMMUNITY_ENABLED: "0" }, { AVATAR_DOWNLOAD_HOSTS_JSON: "[]" },
      { AVATAR_DOWNLOAD_HOSTS_JSON: '["icloud.com"]' }, { AVATAR_DOWNLOAD_HOSTS_JSON: '["private.invalid"]' }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...changes }, f.clock()), null);
    f.setFeature(false); assert.equal((await f.call()).status, 503); assert.equal(f.counts().budgets, 0);
    f.env.AVATAR_OWNER_PREVIEW_ENABLED = "0"; delete f.env.AVATAR_DOWNLOAD_HOSTS_JSON;
    assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarOwnerPreviewEnabled, false); assert.equal((await f.edge()).status, 503);
    delete f.env.AVATAR_OWNER_PREVIEW_ENABLED; assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarOwnerPreviewEnabled, false);
  } finally { f.close(); }
});

test("owner preview rejects malformed media, bearer, headers and bounded bodies before checkpoint", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    for (const [headers, status] of [[{ "Content-Type": "image/jpeg" }, 415], [{ "Content-Encoding": "gzip" }, 415],
      [{ "Content-Length": "513" }, 413], [{ [avatarSelectionHeader]: "{}" }, 400], [{ [avatarManifestHeader]: "{}" }, 400],
      [{ "X-Echoes-Avatar-Review": "{}" }, 400], [{ "X-Echoes-Avatar-Intent": "{}" }, 400]]) assert.equal((await f.call({}, { headers, budget: budget() })).status, status);
    assert.equal((await f.call({}, { token: "bad", budget: budget() })).status, 401);
    for (const rawBody of [" ".repeat(513), "not json", "null"]) assert.ok([400, 413].includes((await f.call({}, { rawBody, budget: budget() })).status));
    assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("owner preview shares persistent image quota before body/checkpoint even across handler restart", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    for (let n = 0; n < 4; n++) { await f.limits.consumeAvatarRead(f.signedIn.accountID, { variant: "image" }); }
    const rebuilt = createGatewayHTTPHandler(f.dependencies);
    const response = await rebuilt(f.request({}, { rawBody: "not json" }), budget());
    assert.equal(response.status, 429); assert.equal((await response.json()).error, "RATE_LIMITED");
    assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("owner preview rechecks moderation, clear, session and flags at download and final response", async () => {
  for (const action of ["revision", "reject", "clear", "session", "flag"]) {
    const f = await avatarOwnerPreviewFixture();
    try {
      const final = await f.preview.prepare(f.selection());
      if (action === "flag") f.setFeature(false);
      else if (action === "session") await f.nextLoginGeneration();
      else if (action === "clear") { const done = await f.coordinator.prepareClear(f.credentials({ requestID: randomUUID(), expectedGeneration: f.current.generation })); await f.checkpoint.advance(); done(); }
      else { const done = await f.coordinator.prepareReview(f.review(f.current, action === "reject" ? "rejected" : "approved")); await f.checkpoint.advance(); done(); }
      assert.throws(() => final(), e => ["AVATAR_READ_NOT_FOUND", "AVATAR_READ_STALE", "AVATAR_READ_UNAVAILABLE"].includes(e?.code));
    } finally { f.close(); }
  }
  const f = await avatarOwnerPreviewFixture();
  try {
    f.setDownloadHook(async () => { const done = await f.coordinator.prepareReview(f.review(f.current, "rejected")); await f.checkpoint.advance(); done(); });
    await assert.rejects(f.preview.prepare(f.selection()), code("AVATAR_READ_NOT_FOUND"));
  } finally { f.close(); }
});

test("owner preview performs its last policy check after HTTP has buffered the JPEG", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    const deps = { ...f.dependencies, avatarOwnerPreview: { async prepare(input) {
      const final = await f.preview.prepare(input);
      return Object.assign(() => { const r = final(); return new Response(new ReadableStream({ async start(c) {
        const done = await f.coordinator.prepareReview(f.review(f.current, "rejected")); await f.checkpoint.advance(); done();
        c.enqueue(new Uint8Array(await r.arrayBuffer())); c.close();
      } }), { headers: r.headers }); }, { validate: final.validate });
    } } };
    const response = await createGatewayHTTPHandler(deps)(f.request(), budget());
    assert.equal(response.status, 404); assert.equal((await response.json()).error, "AVATAR_READ_NOT_FOUND");
  } finally { f.close(); }
});

test("owner preview rejects provider redirects, wrong hashes, truncated bodies and unverified hosts", async () => {
  for (const fault of ["redirect", "hash", "short", "host"]) {
    const f = await avatarOwnerPreviewFixture();
    try {
      if (fault === "host") {
        const content = f.policy.readApprovedOwnerSelection(f.signedIn.accountID, f.body());
        f.model.records.get(content.avatar.recordName).fields.image.value.downloadURL = "https://other.icloud-content.com/private.jpg";
      } else f.setDownloadHook(() => fault === "redirect" ? new Response(null, { status: 302, headers: { Location: "https://private.invalid" } }) :
        new Response(new Uint8Array(fault === "short" ? 1 : f.policy.readApprovedOwnerSelection(f.signedIn.accountID, f.body()).descriptor.image.byteCount), { headers: { "Content-Type": "image/jpeg" } }));
      await assert.rejects(f.preview.prepare(f.selection()), code("AVATAR_READ_RESPONSE"), fault);
    } finally { f.close(); }
  }
});

test("owner preview correlates the full closed proof and image on both response boundaries", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    const final = await f.preview.prepare(f.selection()), source = final(), bytes = new Uint8Array(await source.arrayBuffer());
    for (const fault of ["missing", "revision", "generation", "version", "extra", "owner", "204", "hash"]) {
      const headers = new Headers(source.headers), proof = JSON.parse(headers.get(avatarSelectionHeader));
      if (fault === "missing") headers.delete(avatarSelectionHeader);
      if (fault === "revision") proof.reviewRevision = randomUUID();
      if (fault === "generation") proof.generation++;
      if (fault === "version") proof.versionID = randomUUID();
      if (fault === "extra") proof.operator = true;
      if (!["missing", "owner"].includes(fault)) headers.set(avatarSelectionHeader, JSON.stringify(proof));
      if (fault === "owner") { const manifest = JSON.parse(headers.get(avatarManifestHeader)); manifest.ownerID = randomUUID(); headers.set(avatarManifestHeader, JSON.stringify(manifest)); }
      const response = fault === "204" ? new Response(null, { status: 204, headers }) : new Response(fault === "hash" ? bytes.map(() => 0) : bytes.slice(), { headers });
      const deadline = avatarHTTPDeadline(undefined);
      try { await assert.rejects(avatarOwnerPreviewResponse(response, deadline, { selection: f.body(), accountID: f.signedIn.accountID }), code("AVATAR_READ_RESPONSE")); }
      finally { deadline.close(); }
    }
    const deadline = avatarHTTPDeadline(undefined);
    try { await assert.rejects(avatarOwnerPreviewEdgeResponse(new Response(null, { status: 204 }), deadline), code("AVATAR_READ_RESPONSE")); }
    finally { deadline.close(); }
  } finally { f.close(); }
});

test("owner reader retains admission after timed-out lookup until the ignored dependency settles", async () => {
  const f = await avatarOwnerPreviewFixture(); let release;
  try {
    const blocked = new Promise(resolve => { release = resolve; });
    const reader = new CloudKitAvatarOwnerPreview({ ...f.configuration, isEnabled: () => true, timeoutMilliseconds: 40,
      client: { async lookup(...args) { await blocked; return f.client.lookup(...args); } } });
    await assert.rejects(reader.prepare(f.selection()), code("AVATAR_READ_UNAVAILABLE"));
    await assert.rejects(reader.prepare(f.selection()), code("AVATAR_READ_LIMIT"));
    release(); await immediate(); await immediate();
    await assert.rejects(reader.prepare(f.selection({ reviewRevision: randomUUID() })), code("AVATAR_READ_NOT_FOUND"));
  } finally { release?.(); f.close(); }
});

test("owner HTTP admission remains held through an ignored checkpoint after its total timeout", async () => {
  const f = await avatarOwnerPreviewFixture(); let release;
  try {
    const blocked = new Promise(resolve => { release = resolve; }); let first = true;
    const handle = createGatewayHTTPHandler({ ...f.dependencies, previewTimeoutMilliseconds: 40,
      checkpoint: { async verify() { if (first) { first = false; await blocked; } }, advance: (...args) => f.checkpoint.advance(...args) } });
    assert.equal((await handle(f.request(), budget())).status, 503);
    assert.equal((await handle(f.request(), budget())).status, 429);
    release(); await immediate(); await immediate();
    // A new call is admitted; use the normal budget deadline for the actual image work.
    const result = await handle(f.request({ generation: 0 }), budget()); assert.equal(result.status, 400);
    assert.equal(f.downloads.length, 0);
  } finally { release?.(); f.close(); }
});

test("owner edge rejects an authority response for a different review selection", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    const r = f.request(); Object.defineProperty(r, "cf", { value: { colo: "WAW" } }); r.headers.set("CF-Connecting-IP", "192.0.2.17");
    const final = await f.preview.prepare(f.selection()), source = final(), body = new Uint8Array(await source.arrayBuffer());
    const headers = new Headers(source.headers), proof = JSON.parse(headers.get(avatarSelectionHeader)); proof.reviewRevision = randomUUID(); headers.set(avatarSelectionHeader, JSON.stringify(proof));
    f.env.COMMUNITY_AUTHORITY.get = () => ({ fetch() { return new Response(body.slice(), { headers }); } });
    const response = await forwardGatewayRequest(r, f.env, { clock: f.clock }); assert.equal(response.status, 503);
    assert.equal((await response.json()).error, "AVATAR_READ_RESPONSE");
  } finally { f.close(); }
});

test("owner edge retains admission after cancellation until an ignoring authority returns", async () => {
  const f = await avatarOwnerPreviewFixture(); let release;
  try {
    let reached; const started = new Promise(resolve => { reached = resolve; });
    const blocked = new Promise(resolve => { release = resolve; });
    f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() { reached(); await blocked; return Response.json({ protocolVersion: 1, error: "FEATURE_DISABLED" },
      { status: 503, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }); } });
    const controller = new AbortController(), first = f.edge({}, { signal: controller.signal });
    await started; controller.abort(); assert.equal((await first).status, 503);
    assert.equal((await f.edge()).status, 429); release(); await immediate(); await immediate();
    const response = await f.edge(); assert.equal(response.status, 503); assert.equal((await response.json()).error, "FEATURE_DISABLED");
  } finally { release?.(); f.close(); }
});

test("owner preview denies pending/rejected content without provider reads", async () => {
  for (const status of ["pending-review", "rejected"]) {
    const f = await avatarOwnerPreviewFixture();
    try {
      if (status === "pending-review") { const done = await f.coordinator.prepareUpload(f.upload()); await f.checkpoint.advance(); done(); }
      else { const done = await f.coordinator.prepareReview(f.review(f.current, "rejected")); await f.checkpoint.advance(); done(); }
      const snapshot = f.policy.snapshot(f.signedIn.accountID), { consentVersion, ...selection } = f.publication(snapshot);
      await assert.rejects(f.preview.prepare({ ...selection, accessToken: f.signedIn.sessionToken }), code("AVATAR_READ_NOT_FOUND"));
      assert.equal(f.downloads.length, 0);
    } finally { f.close(); }
  }
});

test("owner preview denies clock rollback and changed asset commitment at finalization", async () => {
  for (const fault of ["clock", "commitment"]) {
    const f = await avatarOwnerPreviewFixture();
    try {
      const final = await f.preview.prepare(f.selection());
      if (fault === "clock") f.advance(-1);
      else f.db.prepare("UPDATE avatar_asset_transfers_v1 SET content_sha256=? WHERE variant='image'").run("0".repeat(64));
      assert.throws(() => final(), e => ["AVATAR_READ_UNAVAILABLE", "AVATAR_READ_RESPONSE"].includes(e?.code));
    } finally { f.close(); }
  }
});

test("owner preview rejects endless/zero/tiny or over-limit body chunks before checkpoint", async () => {
  const f = await avatarOwnerPreviewFixture();
  try {
    for (const empty of [true, false]) {
      let cancelled = false;
      const rawBody = new ReadableStream({ pull(c) { c.enqueue(new Uint8Array(empty ? 0 : 1)); }, cancel() { cancelled = true; } });
      assert.equal((await f.call({}, { rawBody, budget: budget() })).status, 400); assert.equal(cancelled, true);
    }
    assert.equal(f.counts().verifies, 0); assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("owner preview edge bounds errors, enforces code/status, and strips private headers", async () => {
  for (const fault of ["none", "status", "extra", "size", "cache", "code"]) {
    const deadline = avatarHTTPDeadline(undefined);
    try {
      const body = { protocolVersion: 1, error: fault === "code" ? "constructor" : "INVALID_SESSION", ...(fault === "extra" ? { private: true } : {}) };
      const headers = { "Cache-Control": fault === "cache" ? "public" : "no-store", "X-Content-Type-Options": "nosniff", "X-Private-URL": "SYNTHETIC-PRIVATE", "Set-Cookie": "private=1" };
      const response = fault === "size" ? new Response(" ".repeat(2049), { status: 401, headers: { ...headers, "Content-Type": "application/json" } }) :
        Response.json(body, { status: fault === "status" ? 403 : 401, headers });
      if (fault === "none") {
        const result = await avatarOwnerPreviewEdgeResponse(response, deadline); assert.equal(result.status, 401); assert.deepEqual(await result.json(), body);
        assert.equal(result.headers.get("Set-Cookie"), null); assert.equal(result.headers.get("X-Private-URL"), null);
      } else await assert.rejects(avatarOwnerPreviewEdgeResponse(response, deadline), code("AVATAR_READ_RESPONSE"));
    } finally { deadline.close(); }
  }
});
