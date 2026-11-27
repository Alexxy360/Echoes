import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash, generateKeyPairSync, randomUUID, verify } from "node:crypto";
import { mkdtemp, rm, readFile, writeFile, unlink, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeAvatarGrantDiscovery, verifyAvatarGrantDiscovery, discoveredAvatarUploadHosts, avatarGrantDiscoveryCommand } from "../scripts/avatar-grant-discovery.mjs";
import { publishProtocolPrivateJSON } from "../scripts/community-protocol-files.mjs";
import { barrier } from "./support/community-protocol-fixture.mjs";
import { gzipJSONServer } from "./support/gzip-json-server.mjs";

const code = expected => error => error.code === expected;
const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
const grant = prepared => ({ tokens: prepared.plan.request.tokens.map(token => ({ recordName: token.recordName, fieldName: token.fieldName,
  url: `https://synthetic-${token.fieldName}.icloud-content.com/SECRET-PATH?token=SECRET-UPLOAD-TOKEN` })) });

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "echoes-grant-test-")); t.after(() => rm(root, { recursive: true, force: true }));
  const info = await avatarGrantDiscoveryCommand(["prepare", root]);
  const prepared = JSON.parse(await readFile(join(info.directory, "inventory.json"), "utf8"));
  const keyPath = join(info.directory, "synthetic-key.pem"), permitPath = join(info.directory, "permit.json");
  let wall = Date.now(), mono = 0;
  const permit = { schemaVersion: 1, purpose: prepared.plan.purpose, planSHA256: prepared.sha256, scope: prepared.plan.scope,
    window: { id: randomUUID(), issuedAt: wall, expiresAt: wall + 60000 }, keyID: "synthetic-grant-key",
    publicKeySHA256: createHash("sha256").update(pair.publicKey.export({ type: "spki", format: "der" })).digest("hex"),
    identityModel: "individual-owner-administrator-v1" };
  await writeFile(keyPath, pem, { mode: 0o600 }); await publishProtocolPrivateJSON(permitPath, permit);
  const f = { root, info, prepared, keyPath, permitPath, permit, calls: [],
    options: { env: { ECHOES_ALLOW_ASSET_GRANTS_DEV: "1" }, clock: () => wall, monotonic: () => mono,
      fetchImplementation: async (request, options) => { f.calls.push(request); return Response.json(grant(prepared)); } },
    moveWall(ms) { wall += ms; }, moveMono(ms) { mono += ms; },
    args(command = "run") { return [command, info.directory, prepared.sha256, permitPath, keyPath]; },
    async run(options = {}) { return avatarGrantDiscoveryCommand(f.args(), { ...f.options, ...options }); },
  };
  return f;
}

test("grant-only inventory is deterministic and refuses edits, old purposes, foreign scope and extra operations", () => {
  const prepared = makeAvatarGrantDiscovery();
  assert.deepEqual(verifyAvatarGrantDiscovery(prepared), prepared);
  assert.equal(prepared.plan.request.tokens.length, 2); assert.equal(prepared.plan.limits.requests, 1);
  for (const mutate of [p => p.plan.request.tokens[0].recordName = "foreign", p => p.plan.request.tokens.push(p.plan.request.tokens[0]),
    p => p.plan.scope.environment = "production", p => p.plan.uploads = true, p => p.plan.extra = true,
    p => p.plan.purpose = "echoes-community-query-development-v1", p => p.sha256 = "a".repeat(64)]) {
    const bad = structuredClone(prepared); mutate(bad); assert.throws(() => verifyAvatarGrantDiscovery(bad));
  }
  assert.throws(() => makeAvatarGrantDiscovery("not-uuid"));
});

test("private prepare and inspect make no network calls, while disabled run refuses before files or keys", async t => {
  const f = await fixture(t), call = await avatarGrantDiscoveryCommand(["inspect", f.info.directory, f.prepared.sha256], {
    fetchImplementation: async () => { throw new Error("No network"); } });
  assert.equal(call.networkRequests, 0); assert.equal(call.recordWrites, false); assert.equal(call.uploads, false);
  assert.equal((await stat(f.info.directory)).mode & 0o077, 0); assert.equal((await stat(join(f.info.directory, "inventory.json"))).mode & 0o077, 0);
  await assert.rejects(avatarGrantDiscoveryCommand(["run", "/missing", "a".repeat(64), "/missing/permit", "/missing/key"], { env: {} }), code("GRANT_DISABLED"));
  assert.equal(f.calls.length, 0);
});

test("one signed grant request produces only sanitized exact hosts and a nonreusable durable receipt", async t => {
  const f = await fixture(t); let requests = 0;
  f.options.fetchImplementation = async (request, options) => {
    requests++; const body = await request.text(), path = new URL(request.url).pathname;
    assert.equal(request.url, "https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/assets/upload");
    assert.equal(request.method, "POST"); assert.equal(request.redirect, "manual"); assert.deepEqual(JSON.parse(body), f.prepared.plan.request);
    const at = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date"), hash = createHash("sha256").update(body).digest("base64");
    assert.equal(verify("sha256", Buffer.from(`${at}:${hash}:${path}`), pair.publicKey,
      Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64")), true);
    assert.equal(options.signal.aborted, false);
    const reversed = grant(f.prepared); reversed.tokens.reverse(); return Response.json(reversed);
  };
  const result = await f.run();
  assert.equal(requests, 1); assert.equal(result.networkRequests, 1); assert.equal(result.uploadRequests, 0); assert.equal(result.recordWrites, 0);
  assert.deepEqual(result.exactHosts, ["synthetic-image.icloud-content.com", "synthetic-thumbnail.icloud-content.com"]);
  const report = await readFile(join(f.info.directory, "report.json"), "utf8"), attempt = await readFile(join(f.info.directory, "attempt.json"), "utf8");
  assert.deepEqual(JSON.parse(report), result);
  for (const secret of ["SECRET-PATH", "SECRET-UPLOAD-TOKEN", "PRIVATE KEY", f.keyPath]) assert.equal((report + attempt).includes(secret), false);
  await assert.rejects(f.run(), code("GRANT_PRIVATE_FILE"));
  await unlink(join(f.info.directory, "report.json"));
  await assert.rejects(f.run(), code("GRANT_PRIVATE_FILE")); assert.equal(requests, 1);
});

test("malformed grants and unsafe host/URL forms never become a host allowlist", () => {
  const prepared = makeAvatarGrantDiscovery(), good = grant(prepared);
  for (const mutate of [p => p.tokens.pop(), p => p.tokens[0].recordName = "foreign", p => p.tokens[0].fieldName = "private",
    p => p.tokens[1].fieldName = p.tokens[0].fieldName, p => p.tokens[0].extra = "unreviewed", p => p.extra = true,
    ...["http://x.icloud-content.com/a", "https://127.0.0.1/a", "https://[::1]/a", "https://icloud-content.com/a",
      "https://x.icloud-content.com.evil.invalid/a", "https://user:pass@x.icloud-content.com/a",
      "https://x.icloud-content.com:8443/a", "https://x.icloud-content.com:443/a/../b",
      "https://%78.icloud-content.com/a", "https://x.icloud-content.com" + String.fromCharCode(92) + "a", "https://x.icloud-content.com/a#fragment", "https://x.icloud-content.com/a#", "https://x.icloud-content.com/a\n",
      "https://x.icloud-content.com/" + "x".repeat(8192)].map(url => p => p.tokens[0].url = url)]) {
    const bad = structuredClone(good); mutate(bad); assert.throws(() => discoveredAvatarUploadHosts(prepared, bad), code("GRANT_RESPONSE"));
  }
});

test("invalid permit, scope, deadline and SPKI fail before any request or reservation", async t => {
  const f = await fixture(t), good = structuredClone(f.permit);
  for (const mutate of [p => p.purpose = "echoes-community-query-development-v1", p => p.planSHA256 = "b".repeat(64),
    p => p.scope.environment = "production", p => p.window.expiresAt += 1800000, p => p.window.issuedAt += 60001,
    p => p.extra = true, p => p.identityModel = "other",
    p => p.keyID = "0663e7ddc1124c0522589f5db7d0786c19f80c35ac158199db561f6e79a80919"]) {
    const bad = structuredClone(good); mutate(bad); await writeFile(f.permitPath, JSON.stringify(bad));
    await assert.rejects(f.run(), code("GRANT_PERMIT"));
  }
  await writeFile(f.permitPath, JSON.stringify({ ...good, publicKeySHA256: "a".repeat(64) }));
  await assert.rejects(f.run(), code("GRANT_KEY")); assert.equal(f.calls.length, 0);
  await assert.rejects(readFile(join(f.info.directory, "attempt.json")), error => error.code === "ENOENT");
});

test("response redirects, oversized or invalid bodies stop after the sole grant request with a retained attempt", async t => {
  for (const response of [new Response("REDIRECT-SECRET", { status: 302, headers: { Location: "https://evil.invalid/SECRET" } }),
    new Response("SECRET-HTML", { headers: { "Content-Type": "text/html" } }),
    new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "16385" } }),
    new Response(" ".repeat(16385), { headers: { "Content-Type": "application/json" } }),
    new Response(new Uint8Array([0xff]), { headers: { "Content-Type": "application/json" } }),
    Response.json({ serverErrorCode: "BAD_REQUEST", reason: "SECRET-REASON" })]) {
    const f = await fixture(t); let calls = 0;
    await assert.rejects(f.run({ fetchImplementation: async () => { calls++; return response; } }), error =>
      error.code === "GRANT_RESPONSE" && error.requestMayHaveStarted && !error.message.includes("SECRET"));
    assert.equal(calls, 1); await stat(join(f.info.directory, "attempt.json"));
    await assert.rejects(readFile(join(f.info.directory, "report.json")), error => error.code === "ENOENT");
  }
  const f = await fixture(t); let chunks = 0;
  const stream = new ReadableStream({ pull(c) { chunks++; c.enqueue(new Uint8Array()); } });
  await assert.rejects(f.run({ fetchImplementation: async () => new Response(stream, { headers: { "Content-Type": "application/json" } }) }), code("GRANT_RESPONSE"));
  assert.ok(chunks <= 66);
});

test("permission revocation, clock rollback and expiry reject late data without publishing URLs or retrying", async t => {
  for (const mutate of [async f => unlink(f.permitPath), async f => f.moveWall(-1), async f => f.moveMono(-1), async f => f.moveWall(60000)]) {
    const f = await fixture(t); let calls = 0;
    await assert.rejects(f.run({ fetchImplementation: async () => { calls++; await mutate(f); return Response.json(grant(f.prepared)); } }),
      error => error.requestMayHaveStarted === true);
    assert.equal(calls, 1); await assert.rejects(readFile(join(f.info.directory, "report.json")), error => error.code === "ENOENT");
  }
});

test("an aborted uncooperative fetch retains the actual run and prevents a second request until it settles", async t => {
  const f = await fixture(t), entered = barrier(), release = barrier(), controller = new AbortController(); let calls = 0, settled = false;
  const running = f.run({ signal: controller.signal, fetchImplementation: async () => {
    calls++; entered.release(); await release.promise; return Response.json(grant(f.prepared));
  } });
  const checked = assert.rejects(running, code("GRANT_CANCELLED")).then(() => settled = true);
  await entered.promise; controller.abort(); await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
  await assert.rejects(f.run(), code("GRANT_PRIVATE_FILE"));
  release.release(); await checked; assert.equal(calls, 1);
});


test("real fetch decodes gzip grants without confusing compressed length with JSON bytes", async t => {
  const f = await fixture(t), server = await gzipJSONServer(t, () => grant(f.prepared));
  const result = await f.run({ fetchImplementation: (_request, { signal }) => server.fetch(signal) });
  assert.equal(result.status, "hosts_discovered");
  assert.equal(result.networkRequests, 1); assert.equal(server.calls, 1);
  assert.deepEqual(result.exactHosts, ["synthetic-image.icloud-content.com", "synthetic-thumbnail.icloud-content.com"]);
});


test("gzip decoded bodies remain limited even when compressed Content-Length is small", async t => {
  const f = await fixture(t), server = await gzipJSONServer(t, () => ({ padding: "p".repeat(20000) }));
  await assert.rejects(f.run({ fetchImplementation: (_request, { signal }) => server.fetch(signal) }), error => {
    assert.equal(error.code, "GRANT_RESPONSE"); assert.equal(error.diagnostics.contentEncoding, "gzip");
    assert.ok(error.diagnostics.contentLength < 16384);
    assert.equal(error.diagnostics.decodedBytes, 16385); assert.equal(error.diagnostics.responseReason, "body_limit");
    return true;
  });
  assert.equal(server.calls, 1);
  await assert.rejects(f.run(), code("GRANT_PRIVATE_FILE"));
});

test("failure diagnostics identify the rejection without provider text, URL, token or key data", async t => {
  const cases = [
    { reason: "http_status", response: () => new Response("SECRET-BODY", { status: 503, headers: { "Content-Type": "application/json; SECRET-HEADER" } }) },
    { reason: "grant_shape", provider: "BAD_REQUEST", response: () => Response.json({ serverErrorCode: "BAD_REQUEST", reason: "SECRET-REASON", uuid: "SECRET-UUID", redirectURL: "https://secret.invalid/SECRET-PATH" }) },
    { reason: "grant_shape", provider: "OTHER", response: () => Response.json({ serverErrorCode: "SECRET-ERROR", reason: "SECRET-REASON" }) },
    { reason: "token_scope", response: f => { const body = grant(f.prepared); body.tokens[0].recordName = "SECRET-RECORD"; return Response.json(body); } },
    { reason: "url_provider", response: f => { const body = grant(f.prepared); body.tokens[0].url = "https://secret.invalid/SECRET-PATH?token=SECRET-UPLOAD-TOKEN"; return Response.json(body); } },
    { reason: "length_mismatch", response: f => Response.json(grant(f.prepared), { headers: { "Content-Length": "1" } }) },
    { reason: "content_encoding", response: f => Response.json(grant(f.prepared), { headers: { "Content-Encoding": "SECRET-ENCODING" } }) },
  ];
  for (const item of cases) {
    const f = await fixture(t); let calls = 0;
    await assert.rejects(f.run({ fetchImplementation: async () => { calls++; return item.response(f); } }), error => {
      assert.equal(error.code, "GRANT_RESPONSE"); assert.equal(error.requestMayHaveStarted, true);
      assert.equal(error.diagnostics.responseReason, item.reason);
      if (item.provider) assert.equal(error.diagnostics.providerError, item.provider);
      const serialized = JSON.stringify({ errorCode: error.code, diagnostics: error.diagnostics });
      for (const secret of ["SECRET", "secret.invalid", f.keyPath, "PRIVATE KEY"]) assert.equal(serialized.includes(secret), false);
      return true;
    });
    assert.equal(calls, 1);
    await assert.rejects(readFile(join(f.info.directory, "report.json")), error => error.code === "ENOENT");
    await assert.rejects(f.run(), code("GRANT_PRIVATE_FILE"));
  }
});


test("trusted HTTPS authority spellings keep the same host without exposing signed URL data", async t => {
  for (const variant of ["port", "case", "both"]) {
    const f = await fixture(t); let calls = 0;
    const result = await f.run({ fetchImplementation: async () => {
      calls++; const body = grant(f.prepared);
      for (const token of body.tokens) token.url = token.url.replace(/^https:\/\/([^/]+)/, (_all, host) =>
        (variant === "port" ? "https://" + host : "HTTPS://" + host.toUpperCase()) + (variant === "case" ? "" : ":443"));
      return Response.json(body);
    } });
    assert.equal(calls, 1); assert.equal(result.authorityNormalizedURLCount, 2);
    assert.equal(result.defaultHTTPSPortURLCount, variant === "case" ? 0 : 2);
    assert.deepEqual(result.exactHosts, ["synthetic-image.icloud-content.com", "synthetic-thumbnail.icloud-content.com"]);
    assert.equal(JSON.stringify(result).includes("SECRET"), false);
  }
});
