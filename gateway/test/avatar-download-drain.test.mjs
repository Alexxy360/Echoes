import test from "node:test";
import assert from "node:assert/strict";
import { AvatarDownloadScope } from "../src/avatar-protected-download.mjs";
import { CloudKitAvatarOwnerPreview } from "../src/cloudkit-avatar-owner-preview.mjs";
import { avatarReadFixture } from "./support/avatar-read-fixture.mjs";
import { avatarReviewFixture } from "./support/avatar-review-fixture.mjs";
import { avatarOwnerPreviewFixture } from "./support/avatar-owner-preview-fixture.mjs";

const pause = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
const code = value => error => error?.code === value;
const client = { async waitForPendingOperations() {} };
const options = signal => ({ url: "https://synthetic-avatar.icloud-content.com/private/test", manifest: { byteCount: 1 }, signal,
  check() { if (signal.aborted) throw new Error("synthetic cancellation"); } });
const closedBody = () => new Response(new Uint8Array([42]), { headers: { "Content-Type": "image/jpeg", "Content-Length": "1" } });

function stalledBody({ mime = "image/jpeg", reject = false } = {}) {
  const entered = pause(), release = pause(); let cancels = 0;
  const response = new Response(new ReadableStream({
    cancel() { cancels++; entered.resolve(); return reject ? Promise.reject(new Error("SYNTHETIC_PRIVATE_CANCEL_DETAIL")) : release.promise; }
  }), { headers: { "Content-Type": mime, "Content-Length": "1" } });
  return { response, entered, release, count: () => cancels };
}
async function eventually(action) {
  for (let i = 0; i < 300; i++) {
    try { return await action(); }
    catch (error) {
      if (!["AVATAR_READ_LIMIT", "AVATAR_REVIEW_CAPACITY"].includes(error.code)) throw error;
      await new Promise(resolve => setTimeout(resolve, 2));
    }
  }
  assert.fail("Own confirmed cleanup did not release admission");
}

test("download header rejection waits for the exact body cancellation and never retries it", async () => {
  const scope = new AvatarDownloadScope(), operation = scope.operation(), body = stalledBody({ mime: "text/html" });
  operation.adopt(body.response); let settled = false;
  const reading = operation.read(options(new AbortController().signal)).catch(error => { settled = true; return error; });
  await body.entered.promise; await tick(); assert.equal(settled, false); assert.equal(body.count(), 1);
  body.release.resolve(); const error = await reading;
  assert.equal(error.code, "AVATAR_DOWNLOAD_RESPONSE"); await operation.finish(client);
  assert.equal(body.count(), 1); scope.check();
});

test("download reader abort preserves the first cancellation promise and lock until completion", async () => {
  const scope = new AvatarDownloadScope(), operation = scope.operation(), body = stalledBody(), controller = new AbortController();
  operation.adopt(body.response); let settled = false;
  const reading = operation.read(options(controller.signal)).catch(error => { settled = true; return error; });
  await tick(); assert.equal(body.response.body.locked, true); controller.abort(); await body.entered.promise;
  await tick(); assert.equal(settled, false); assert.equal(body.count(), 1); assert.equal(body.response.body.locked, true);
  body.release.resolve(); await reading; await operation.finish(client);
  assert.equal(body.count(), 1); assert.equal(body.response.body.locked, false); scope.check();
});

test("failed download cancellation permanently closes its scope without leaking provider details", async () => {
  for (const mime of ["text/html", "image/jpeg"]) {
    const scope = new AvatarDownloadScope(), operation = scope.operation(), body = stalledBody({ mime, reject: true });
    const controller = new AbortController(); operation.adopt(body.response);
    const reading = operation.read(options(controller.signal)).catch(error => error);
    if (mime === "image/jpeg") { await tick(); controller.abort(); }
    const error = await reading;
    assert.equal(error.code, "AVATAR_DOWNLOAD_RESPONSE"); assert.doesNotMatch(String(error), /SYNTHETIC_PRIVATE_CANCEL_DETAIL/);
    await assert.rejects(() => operation.finish(client), code("AVATAR_DOWNLOAD_RESPONSE"));
    await assert.rejects(() => operation.finish(client), code("AVATAR_DOWNLOAD_RESPONSE"));
    assert.throws(() => scope.operation(), code("AVATAR_DOWNLOAD_RESPONSE")); assert.equal(body.count(), 1);
  }
});

test("foreign locked download is never stolen or treated as drained after its lock is released", async () => {
  const scope = new AvatarDownloadScope(), operation = scope.operation(), body = stalledBody(), foreign = body.response.body.getReader();
  operation.adopt(body.response);
  await assert.rejects(() => operation.finish(client), code("AVATAR_DOWNLOAD_RESPONSE")); assert.equal(body.count(), 0);
  foreign.releaseLock(); assert.throws(() => scope.check(), code("AVATAR_DOWNLOAD_RESPONSE"));
  body.release.resolve(); await body.response.body.cancel();
});

test("healthy download and ordinary validation errors do not poison confirmed cleanup", async () => {
  const scope = new AvatarDownloadScope();
  for (const mime of ["text/html", "image/jpeg"]) {
    const operation = scope.operation(), response = closedBody(); response.headers.set("Content-Type", mime); operation.adopt(response);
    if (mime === "text/html") await assert.rejects(() => operation.read(options(new AbortController().signal)), code("AVATAR_DOWNLOAD_RESPONSE"));
    else assert.deepEqual(await operation.read(options(new AbortController().signal)), new Uint8Array([42]));
    await operation.finish(client); scope.check();
  }
});

test("all four avatar slots stay occupied until invalid-response body cancellation actually finishes", async () => {
  const f = await avatarReadFixture(), bodies = Array.from({ length: 4 }, () => stalledBody({ mime: "text/html" }));
  let arrivals = 0; const controllers = bodies.map(() => new AbortController());
  try {
    f.setDownloadHook(() => bodies[arrivals++]?.response);
    const pending = controllers.map(c => f.reader.prepare(f.input({ signal: c.signal })).catch(error => error));
    await Promise.all(bodies.map(body => body.entered.promise)); controllers.forEach(c => c.abort());
    assert.ok((await Promise.all(pending)).every(error => error.code === "AVATAR_READ_UNAVAILABLE"));
    await tick(); await assert.rejects(() => f.reader.prepare(f.input()), code("AVATAR_READ_LIMIT"));
    bodies[0].release.resolve();
    await eventually(async () => { const final = await f.reader.prepare(f.input()); await final().arrayBuffer(); });
    assert.ok(bodies.every(body => body.count() === 1));
  } finally {
    bodies.forEach(body => body.release.resolve()); await f.client.waitForPendingOperations(); await tick(); f.close();
  }
});

test("failed peer image cancellation stops subsequent reads before any further provider call", async () => {
  const f = await avatarReadFixture(); const body = stalledBody({ mime: "text/html", reject: true });
  try {
    f.setDownloadHook(() => body.response);
    await assert.rejects(() => f.reader.prepare(f.input()), code("AVATAR_READ_RESPONSE"));
    const count = f.downloads.length;
    await assert.rejects(() => f.reader.prepare(f.input()), code("AVATAR_READ_RESPONSE"));
    assert.equal(f.downloads.length, count); assert.equal(body.count(), 1);
  } finally { f.close(); }
});

test("owner late fetch after cancellation retains its slot through the returned response body drain", async () => {
  const f = await avatarOwnerPreviewFixture(), fetched = pause(), returnResponse = pause(), body = stalledBody({ mime: "text/html" });
  const controller = new AbortController();
  try {
    f.setDownloadHook(async () => { fetched.resolve(); await returnResponse.promise; return body.response; });
    const pending = f.preview.prepare({ ...f.selection(), signal: controller.signal }).catch(error => error);
    await fetched.promise; controller.abort(); assert.equal((await pending).code, "AVATAR_READ_UNAVAILABLE");
    returnResponse.resolve(); await body.entered.promise;
    await assert.rejects(() => f.preview.prepare(f.selection()), code("AVATAR_READ_LIMIT"));
    body.release.resolve(); f.setDownloadHook(undefined);
    await eventually(async () => { const final = await f.preview.prepare(f.selection()); await final().arrayBuffer(); });
    assert.equal(body.count(), 1);
  } finally { returnResponse.resolve(); body.release.resolve(); await f.client.waitForPendingOperations(); await tick(); f.close(); }
});

test("moderation failed body cancellation keeps admission closed and cannot produce an inspection receipt", async () => {
  const f = await avatarReviewFixture(), body = stalledBody({ mime: "text/html", reject: true });
  try {
    f.setDownloadHook(() => body.response);
    await assert.rejects(() => f.coordinator.prepareInspection(f.inspection()), code("AVATAR_REVIEW_RESPONSE"));
    await assert.rejects(() => f.coordinator.prepareQueue(f.input()), code("AVATAR_REVIEW_CAPACITY"));
    assert.equal(f.downloads.length, 1); assert.equal(body.count(), 1);
    const rows = f.storage.sql.exec("SELECT verified FROM avatar_review_receipts_v1").toArray();
    assert.ok(rows.every(row => row.verified === 0));
  } finally { f.close(); }
});

test("owner waits for the concrete CloudKit pending operations even when lookup already rejected", async () => {
  const f = await avatarOwnerPreviewFixture(), entered = pause(), released = pause(), controller = new AbortController(); let first = true;
  try {
    const wrapper = {
      async lookup(...args) { if (first) { first = false; throw new Error("SYNTHETIC_PRIVATE_LOOKUP"); } return f.client.lookup(...args); },
      async waitForPendingOperations() { entered.resolve(); await released.promise; return f.client.waitForPendingOperations(); }
    };
    const preview = new CloudKitAvatarOwnerPreview({ ...f.configuration, client: wrapper, isEnabled: () => true });
    const pending = preview.prepare({ ...f.selection(), signal: controller.signal }).catch(error => error);
    await entered.promise; controller.abort(); assert.equal((await pending).code, "AVATAR_READ_UNAVAILABLE");
    await assert.rejects(() => preview.prepare(f.selection()), code("AVATAR_READ_LIMIT"));
    released.resolve(); await eventually(async () => { const final = await preview.prepare(f.selection()); await final().arrayBuffer(); });
  } finally { released.resolve(); await f.client.waitForPendingOperations(); await tick(); f.close(); }
});


test("rejected concrete CloudKit drain prevents owner reuse even after a fully downloaded valid image", async () => {
  const f = await avatarOwnerPreviewFixture(); let calls = 0;
  try {
    const wrapper = { lookup: (...args) => f.client.lookup(...args),
      async waitForPendingOperations() { calls++; await f.client.waitForPendingOperations(); throw new Error("SYNTHETIC_PRIVATE_DRAIN_DETAIL"); } };
    const preview = new CloudKitAvatarOwnerPreview({ ...f.configuration, client: wrapper, isEnabled: () => true });
    await assert.rejects(() => preview.prepare(f.selection()), error => {
      assert.equal(error.code, "AVATAR_READ_RESPONSE"); assert.doesNotMatch(String(error), /SYNTHETIC_PRIVATE_DRAIN_DETAIL/); return true;
    });
    const count = f.downloads.length;
    await assert.rejects(() => preview.prepare(f.selection()), code("AVATAR_READ_LIMIT"));
    assert.equal(f.downloads.length, count); assert.equal(calls, 1);
  } finally { f.close(); }
});

test("moderation queue retains its slot and original authority while concrete provider drain is pending", async () => {
  const f = await avatarReviewFixture(), entered = pause(), released = pause(), controller = new AbortController();
  try {
    const wrapper = { lookup: (...args) => f.client.lookup(...args),
      async waitForPendingOperations() { entered.resolve(); await released.promise; return f.client.waitForPendingOperations(); } };
    const review = f.makeReview({ client: wrapper });
    const pending = review.prepareQueue(f.input({ signal: controller.signal })).catch(error => error);
    await entered.promise; controller.abort(); assert.equal((await pending).code, "AVATAR_REVIEW_UNAVAILABLE");
    await assert.rejects(() => review.prepareQueue(f.input()), code("AVATAR_REVIEW_CAPACITY"));
    released.resolve();
    await eventually(async () => { const final = await review.prepareQueue(f.input()); assert.equal(final().items.length, 1); });
    assert.equal(f.downloads.length, 0);
  } finally { released.resolve(); await f.client.waitForPendingOperations(); await tick(); f.close(); }
});
