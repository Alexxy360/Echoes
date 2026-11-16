import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarReadFixture } from "./support/avatar-read-fixture.mjs";
import { avatarManifestHeader } from "../src/cloudkit-avatar-reader.mjs";
import { digest, recordIdentity } from "../src/public-record-schema.mjs";
const code = expected => e => e?.code === expected && e.message === "Profile photo could not be loaded." && e.cause === undefined;
const notFound = code("AVATAR_READ_NOT_FOUND"), responseError = code("AVATAR_READ_RESPONSE");
const pause = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

for (const variant of ["image", "thumbnail"]) test(`protected ${variant} read returns actual normalized JPEG and exact manifest without provider URLs/credentials`, async () => {
  const f = await avatarReadFixture();
  try {
    const response = await f.read({ variant }), manifest = JSON.parse(response.headers.get(avatarManifestHeader));
    const bytes = new Uint8Array(await response.arrayBuffer());
    assert.equal(response.status, 200); assert.equal(response.headers.get("Cache-Control"), "private, no-store");
    assert.equal(response.headers.get("Content-Type"), "image/jpeg"); assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
    assert.equal(bytes.length, manifest.byteCount); assert.equal(digest(bytes), manifest.sha256);
    assert.equal(manifest.ownerID, f.signedIn.accountID); assert.equal(manifest.versionID, f.photo.versionID); assert.equal(manifest.variant, variant);
    for (const secret of ["downloadURL", "receipt", "wrappingKey", "SYNTHETIC-URL", "icloud-content.com"]) assert.equal(JSON.stringify([...response.headers]).includes(secret), false);
    assert.equal(f.downloads.length, 1); assert.equal(f.downloads[0].request.headers.has("Authorization"), false);
  } finally { f.close(); }
});

test("cache revalidation is freshly authorized with no body/download and stale cache hashes fetch the actual image", async () => {
  const f = await avatarReadFixture();
  try {
    const first = await f.read(), manifest = JSON.parse(first.headers.get(avatarManifestHeader)); await first.arrayBuffer();
    const valid = await f.read({ knownSHA256: manifest.sha256 });
    assert.equal(valid.status, 204); assert.equal((await valid.arrayBuffer()).byteLength, 0);
    assert.deepEqual(JSON.parse(valid.headers.get(avatarManifestHeader)), manifest); assert.equal(valid.headers.has("Content-Length"), false);
    assert.equal(valid.headers.get("Cache-Control"), "private, no-store"); assert.equal(f.downloads.length, 1);
    assert.equal((await f.read({ knownSHA256: "0".repeat(64) })).status, 200); assert.equal(f.downloads.length, 2);
  } finally { f.close(); }
});

test("owner reads do not require GPS or an active map presence but peers do", async () => {
  const f = await avatarReadFixture();
  try {
    await f.callCommunity(f.signedIn, "stop", { requestID: randomUUID(), generation: 0 });
    const own = await f.read({ accessToken: f.signedIn.sessionToken, coordinate: undefined }); assert.equal(own.status, 200); await own.arrayBuffer();
    await assert.rejects(() => f.read(), notFound);
    await assert.rejects(() => f.read({ coordinate: undefined }), code("AVATAR_READ_INPUT"));
  } finally { f.close(); }
});

test("far coordinates, stale version, missing publication and both directions of a block never fetch a file", async () => {
  const f = await avatarReadFixture();
  try {
    await assert.rejects(() => f.read({ coordinate: { latitude: 52.2297, longitude: 21.0122 } }), notFound);
    await assert.rejects(() => f.read({ versionID: randomUUID() }), notFound);
    await f.callCommunity(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: true, generation: 0 });
    await assert.rejects(() => f.read(), notFound);
    f.advance(1000); await f.callCommunity(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: false, generation: 1 });
    await f.callCommunity(f.signedIn, "block", { requestID: randomUUID(), accountID: f.viewer.accountID, blocked: true, generation: 0 });
    await assert.rejects(() => f.read(), notFound); assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

for (const change of ["clear", "block", "suspend", "presence"]) test(`${change} during download prevents response finalization`, async () => {
  const f = await avatarReadFixture(), entered = pause(), resume = pause();
  try {
    f.setDownloadHook(async () => { entered.resolve(); await resume.promise; });
    const reading = f.read(), outcome = reading.catch(e => e); await entered.promise;
    if (change === "clear") await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.photo.generation }));
    if (change === "block") await f.callCommunity(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: true, generation: 0 });
    if (change === "suspend") await f.social.setSuspended(f.signedIn.accountID, true);
    if (change === "presence") await f.callCommunity(f.signedIn, "stop", { requestID: randomUUID(), generation: 0 });
    resume.resolve(); assert.equal((await outcome).code, "AVATAR_READ_NOT_FOUND");
  } finally { resume.resolve(); f.close(); }
});

test("approval ABA and republish invalidate an already prepared response", async () => {
  const f = await avatarReadFixture();
  try {
    const finalize = await f.reader.prepare(f.input()), status = f.policy.snapshot(f.signedIn.accountID);
    await f.call("prepareReview", f.review(status, "rejected"));
    await f.call("prepareReview", f.review(f.policy.snapshot(f.signedIn.accountID), "approved"));
    await f.call("preparePublish", f.credentials({ requestID: status.requestID }));
    assert.throws(() => finalize(), notFound); assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("cache hits recheck policy after the final checkpoint and cannot be used after withdrawal", async () => {
  const f = await avatarReadFixture();
  try {
    const first = await f.read(), manifest = JSON.parse(first.headers.get(avatarManifestHeader)); await first.arrayBuffer();
    const finalize = await f.reader.prepare(f.input({ knownSHA256: manifest.sha256 }));
    await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.photo.generation }));
    assert.throws(() => finalize(), notFound); assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("new author login generation preserves published photos without renewing a mutation on the author's behalf", async () => {
  const f = await avatarReadFixture();
  try {
    const before = f.registry.readable(recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName, "avatar");
    await f.nextLoginGeneration(); const response = await f.read(); assert.equal(response.status, 200); await response.arrayBuffer();
    const after = f.registry.readable(before.recordName, "avatar"); assert.deepEqual(after, before);
    assert.throws(() => f.registry.assertMutationCurrent(before));
  } finally { f.close(); }
});

test("unverified, redirected and noncanonical provider URLs never dispatch a download", async () => {
  for (const url of ["http://synthetic-avatar.icloud-content.com/file", "https://evil.invalid/file", "https://synthetic-avatar.icloud-content.com:443/file",
    "https://user@synthetic-avatar.icloud-content.com/file", "https://synthetic-avatar.icloud-content.com/file#fragment"]) {
    const f = await avatarReadFixture();
    try {
      const name = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName;
      f.model.records.get(name).fields.thumbnail.value.downloadURL = url;
      await assert.rejects(() => f.read(), responseError); assert.equal(f.downloads.length, 0);
    } finally { f.close(); }
  }
});

test("redirect, partial, oversized, encoded, truncated, mismatching or non-JPEG file responses fail closed", async () => {
  for (const response of [() => new Response(null, { status: 302, headers: { Location: "https://evil.invalid" } }),
    () => new Response(new Uint8Array(1), { status: 206, headers: { "Content-Type": "image/jpeg" } }),
    () => new Response(new Uint8Array(32001), { headers: { "Content-Type": "image/jpeg" } }),
    () => new Response(new Uint8Array(1), { headers: { "Content-Type": "image/jpeg", "Content-Encoding": "gzip" } }),
    () => new Response(new Uint8Array(1), { headers: { "Content-Type": "image/jpeg" } }),
    () => new Response("bad", { headers: { "Content-Type": "text/html" } })]) {
    const f = await avatarReadFixture();
    try { f.setDownloadHook(response); await assert.rejects(() => f.read(), responseError); assert.equal(f.downloads.length, 1); }
    finally { f.close(); }
  }
});

test("same-size byte corruption cannot pass the normalized server SHA-256", async () => {
  const f = await avatarReadFixture();
  try {
    f.setDownloadHook(() => {
      const name = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName, bytes = f.uploadedBytes.get(name + "/thumbnail").slice();
      bytes[Math.floor(bytes.length / 2)] ^= 1;
      return new Response(bytes, { headers: { "Content-Type": "application/octet-stream", "Content-Length": String(bytes.length) } });
    });
    await assert.rejects(() => f.read(), responseError);
  } finally { f.close(); }
});

test("request-local tickets are one-use, expire and bound four prepared buffers without losing slots", async () => {
  const f = await avatarReadFixture();
  try {
    const tickets = [];
    for (let i = 0; i < 4; i++) tickets.push(await f.reader.prepare(f.input()));
    await assert.rejects(() => f.reader.prepare(f.input()), code("AVATAR_READ_LIMIT"));
    const response = tickets[0](); await response.arrayBuffer(); assert.throws(() => tickets[0](), code("AVATAR_READ_UNAVAILABLE"));
    const next = await f.reader.prepare(f.input()); const second = next(); await second.arrayBuffer();
    f.advance(8000);
    for (const finalize of tickets.slice(1)) assert.throws(() => finalize(), code("AVATAR_READ_UNAVAILABLE"));
    assert.equal((await f.read()).status, 200);
  } finally { f.close(); }
});

test("malformed input and disabled configuration fail without provider reads", async () => {
  const f = await avatarReadFixture();
  try {
    for (const change of [{ ownerID: "../other" }, { versionID: "bad" }, { variant: "raw" }, { knownSHA256: "bad" }, { url: "https://evil.invalid" },
      { coordinate: { latitude: NaN, longitude: 0 } }, { coordinate: { latitude: 0, longitude: 0, extra: true } }]) {
      await assert.rejects(() => f.reader.prepare(f.input(change)), code("AVATAR_READ_INPUT"));
    }
    for (const change of [{ verifiedDownloadHosts: [] }, { verifiedDownloadHosts: ["*.icloud.com"] }, { verifiedDownloadHosts: ["localhost"] }, { timeoutMilliseconds: 8001 }]) {
      assert.throws(() => f.makeReader(change), code("AVATAR_READ_INPUT"));
    }
    f.disableReader(); await assert.rejects(() => f.read(), code("AVATAR_READ_UNAVAILABLE")); assert.equal(f.downloads.length, 0);
  } finally { f.close(); }
});

test("cancellation before, during and after download discards the ticket and releases its slot", async () => {
  const f = await avatarReadFixture(); let release;
  try {
    const before = new AbortController(); before.abort();
    await assert.rejects(() => f.read({ signal: before.signal }), code("AVATAR_READ_UNAVAILABLE"));
    const entered = pause(), held = pause(); release = held.resolve;
    const during = new AbortController();
    f.setDownloadHook(async () => { entered.resolve(); await held.promise; });
    const reading = f.read({ signal: during.signal }), outcome = reading.catch(e => e); await entered.promise; during.abort();
    assert.equal((await outcome).code, "AVATAR_READ_UNAVAILABLE"); held.resolve(); f.setDownloadHook(undefined);
    const after = new AbortController(), finalize = await f.reader.prepare(f.input({ signal: after.signal })); after.abort();
    assert.throws(() => finalize(), code("AVATAR_READ_UNAVAILABLE"));
    const response = await f.read(); assert.equal(response.status, 200); await response.arrayBuffer();
  } finally { release?.(); f.close(); }
});

test("whole-read timeout wins even when fetch ignores abort and the model clock is frozen", async () => {
  const f = await avatarReadFixture(); let release;
  try {
    const held = pause(); release = held.resolve; f.setDownloadHook(async () => { await held.promise; });
    await assert.rejects(() => f.read({}, f.makeReader({ timeoutMilliseconds: 200 })), code("AVATAR_READ_UNAVAILABLE"));
    assert.equal(f.downloads.length, 1); held.resolve(); f.setDownloadHook(undefined);
  } finally { release?.(); f.close(); }
});

test("the monotonic deadline is checked inside fragmented body processing and all stream bytes are bounded", async () => {
  const f = await avatarReadFixture();
  try {
    const name = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName, bytes = f.uploadedBytes.get(name + "/thumbnail");
    for (const kind of ["clock", "fragments", "zero", "length"]) {
      f.setDownloadHook(() => {
        if (kind === "length") return new Response(bytes, { headers: { "Content-Type": "image/jpeg", "Content-Length": "1" } });
        let n = 0;
        return new Response(new ReadableStream({ pull(controller) {
          if (kind === "clock") { f.advance(8000); controller.enqueue(bytes.slice()); controller.close(); }
          else if (kind === "zero") controller.enqueue(new Uint8Array());
          else if (n < bytes.length) controller.enqueue(bytes.slice(n, ++n));
          else controller.close();
        } }), { headers: { "Content-Type": "image/jpeg" } });
      });
      await assert.rejects(() => f.read(), code(kind === "clock" ? "AVATAR_READ_UNAVAILABLE" : "AVATAR_READ_RESPONSE"));
    }
  } finally { f.close(); }
});

test("a newly active block in the last remote checkpoint prevents even the completed image from leaving", async () => {
  const { inputHash, normalizePublicInput } = await import("../src/public-record-schema.mjs");
  const f = await avatarReadFixture();
  try {
    let changed = false;
    f.model.afterCheckpoint = async call => {
      if (call.operation === "modify" && f.downloads.length && !changed) {
        changed = true;
        await f.social.begin({ accountID: f.viewer.accountID, kind: "block", logicalID: f.signedIn.accountID, requestID: randomUUID(), generation: 0,
          payloadHash: inputHash(normalizePublicInput("block", { targetID: f.signedIn.accountID, blocked: true }, f.clock())), active: true });
      }
    };
    await assert.rejects(() => f.read(), notFound); assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("presence can expire during a short download while the viewer session stays fresh", async () => {
  const f = await avatarReadFixture();
  try {
    f.advance(599990); const fresh = await f.session("synthetic.reader");
    f.setDownloadHook(() => { f.advance(11); });
    await assert.rejects(() => f.read({ accessToken: fresh.sessionToken }), notFound);
  } finally { f.close(); }
});

test("account erasure during file retrieval fences the response and removes all publication metadata", async () => {
  const f = await avatarReadFixture(), entered = pause(), resume = pause();
  try {
    f.setDownloadHook(async () => { entered.resolve(); await resume.promise; });
    const reading = f.read(), outcome = reading.catch(e => e); await entered.promise;
    const ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket); resume.resolve();
    assert.equal((await outcome).code, "AVATAR_READ_NOT_FOUND"); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_jobs_v1").get().n, 0);
  } finally { resume.resolve(); f.close(); }
});

test("tampered record fields or transfer commitments cannot produce an asset GET", async () => {
  for (const mutate of [(f, r) => { r.fields.thumbnail.value.fileChecksum = "DIFFERENT"; }, (f, r) => { r.fields.versionID.value = randomUUID(); },
    (f, r) => { r.fields.extra = { value: "unexpected" }; }, (f, r) => { r.recordChangeTag = "changed"; },
    f => { f.db.exec("UPDATE avatar_asset_transfers_v1 SET file_checksum_hash='" + "0".repeat(64) + "'"); }]) {
    const f = await avatarReadFixture();
    try {
      const name = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName; mutate(f, f.model.records.get(name));
      await assert.rejects(() => f.read(), responseError); assert.equal(f.downloads.length, 0);
    } finally { f.close(); }
  }
});

test("revoked viewer sessions cannot revalidate a cached image", async () => {
  const f = await avatarReadFixture();
  try {
    const first = await f.read(), manifest = JSON.parse(first.headers.get(avatarManifestHeader)); await first.arrayBuffer();
    await f.state.disableAccount(f.viewer.accountID);
    await assert.rejects(() => f.read({ knownSHA256: manifest.sha256 }), code("AVATAR_READ_STALE")); assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});

test("a SQLite rollback never revalidates an image against an obsolete publication state", async () => {
  const { sqliteSnapshot, restoreSQLite } = await import("./support/sqlite-snapshot.mjs");
  const f = await avatarReadFixture();
  try {
    const first = await f.read(), manifest = JSON.parse(first.headers.get(avatarManifestHeader)); await first.arrayBuffer();
    const snapshot = sqliteSnapshot(f.db);
    await f.social.setSuspended(f.signedIn.accountID, true); await f.checkpoint.advance();
    restoreSQLite(f.storage, snapshot);
    await assert.rejects(() => f.read({ knownSHA256: manifest.sha256 }), code("AVATAR_READ_UNAVAILABLE")); assert.equal(f.downloads.length, 1);
  } finally { f.close(); }
});
