import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { publicClient } from "./support/public-record-fixture.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
import { reportHTTPFixture } from "./support/report-review-http-fixture.mjs";

const code = value => error => error?.code === value && !error.message.includes("PRIVATE") && error.cause === undefined;
const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
const name = () => recordIdentity(randomUUID(), "message", randomUUID()).recordName;
const absent = recordName => Response.json({ records: [{ recordName, serverErrorCode: "NOT_FOUND" }] });

test("all pre-parser rejection paths retain pending IO through actual response cancellation", async () => {
  for (const make of [body => new Response(body, { headers: { "Content-Type": "text/html" } }),
    body => new Response(body, { status: 503 }), body => new Response(body, { headers: { "Content-Type": "application/json", "Content-Length": "524289" } })]) {
    const entered = barrier(), release = barrier(); let drained = false;
    const stream = new ReadableStream({ cancel() { entered.release(); return release.promise; } });
    const client = publicClient(async () => make(stream)), running = client.lookup([name()]).catch(error => error);
    await entered.promise; const drain = client.waitForPendingOperations().then(() => drained = true); await tick(); assert.equal(drained, false);
    release.release(); assert.ok((await running).code.startsWith("PUBLIC_")); await drain; assert.equal(drained, true);
  }
});

test("failed pre-parser cancellation refuses positive drain and every later dispatch", async () => {
  let calls = 0;
  const stream = new ReadableStream({ cancel() { throw new Error("PRIVATE-CANCEL-FAILURE"); } });
  const client = publicClient(async () => { calls++; return new Response(stream, { headers: { "Content-Type": "text/html" } }); });
  await assert.rejects(client.lookup([name()]), code("PUBLIC_UNAVAILABLE"));
  await assert.rejects(client.waitForPendingOperations(), code("PUBLIC_UNAVAILABLE"));
  await assert.rejects(client.lookup([name()]), code("PUBLIC_UNAVAILABLE")); assert.equal(calls, 1);
});

test("failed reader cancellation after parent abort cannot be converted into a successful drain", async () => {
  const controller = new AbortController(); let calls = 0;
  const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"records":[')); }, cancel() { throw new Error("PRIVATE-READER-CANCEL"); } });
  const client = publicClient(async () => { calls++; return new Response(stream, { headers: { "Content-Type": "application/json" } }); });
  const running = client.lookup([name()], { signal: controller.signal }); await tick(); controller.abort();
  await assert.rejects(running, code("PUBLIC_UNAVAILABLE")); await assert.rejects(client.waitForPendingOperations(), code("PUBLIC_UNAVAILABLE"));
  await assert.rejects(client.lookup([name()]), code("PUBLIC_UNAVAILABLE")); assert.equal(calls, 1);
});

test("a foreign locked response cannot be drained by this client and blocks subsequent IO", async () => {
  const response = absent(name()), reader = response.body.getReader(); let calls = 0;
  const client = publicClient(async () => { calls++; return response; });
  try {
    await assert.rejects(client.lookup([name()]), code("PUBLIC_UNAVAILABLE")); await assert.rejects(client.waitForPendingOperations(), code("PUBLIC_UNAVAILABLE"));
    await assert.rejects(client.lookup([name()]), code("PUBLIC_UNAVAILABLE")); assert.equal(calls, 1);
  } finally { await reader.cancel(); reader.releaseLock(); }
});

test("a late fetch after abort still retains its invalid response until cancellation actually finishes", async () => {
  const fetchEntered = barrier(), fetchRelease = barrier(), cancelEntered = barrier(), cancelRelease = barrier(), controller = new AbortController();
  const recordName = name(); let calls = 0, drained = false;
  const client = publicClient(async () => {
    if (++calls > 1) return absent(recordName);
    fetchEntered.release(); await fetchRelease.promise;
    return new Response(new ReadableStream({ cancel() { cancelEntered.release(); return cancelRelease.promise; } }), { headers: { "Content-Type": "text/html" } });
  });
  const running = client.lookup([recordName], { signal: controller.signal }); await fetchEntered.promise; controller.abort();
  await assert.rejects(running, code("PUBLIC_UNAVAILABLE")); const drain = client.waitForPendingOperations().then(() => drained = true);
  fetchRelease.release(); await cancelEntered.promise; await tick(); assert.equal(drained, false);
  cancelRelease.release(); await drain; assert.equal((await client.lookup([recordName])).get(recordName).serverErrorCode, "NOT_FOUND");
});

test("activation must be synchronous true; truthy values and resolving or rejecting promises cannot dispatch", async () => {
  for (const isEnabled of [() => 1, async () => true, () => Promise.reject(new Error("PRIVATE-FLAG"))]) {
    let calls = 0; const client = publicClient(async () => { calls++; return absent(name()); }, { isEnabled });
    await assert.rejects(client.lookup([name()]), code("PUBLIC_UNAVAILABLE")); await tick(); assert.equal(calls, 0);
  }
});

test("moderation HTTP cannot checkpoint or dispatch further provider work after an unsafe client drain", async t => {
  const f = await reportHTTPFixture(t); let failed = false;
  f.model.before = () => {
    if (!failed) { failed = true; return new Response(new ReadableStream({ cancel() { throw new Error("PRIVATE-CANCEL"); } }), { headers: { "Content-Type": "text/html" } }); }
  };
  let response = await f.call("inspect"); assert.equal(response.status, 503); assert.equal(JSON.stringify(await response.json()).includes("PRIVATE"), false);
  await f.review.waitForPendingOperations(); assert.equal(f.review.isOccupied, true);
  await assert.rejects(f.client.waitForPendingOperations(), code("PUBLIC_UNAVAILABLE"));
  const before = f.model.requests.length + f.model.checkpointRequests.length;
  response = await f.call("queue"); assert.equal(response.status, 503); assert.equal(f.model.requests.length + f.model.checkpointRequests.length, before);
});

test("an ordinary JSON validation error with completed cancellation leaves the client usable", async () => {
  const recordName = name(); let calls = 0;
  const client = publicClient(async () => ++calls === 1 ? new Response("PRIVATE-INVALID-JSON", { headers: { "Content-Type": "application/json" } }) : absent(recordName));
  await assert.rejects(client.lookup([recordName]), code("PUBLIC_UNAVAILABLE")); await client.waitForPendingOperations();
  assert.equal((await client.lookup([recordName])).get(recordName).serverErrorCode, "NOT_FOUND"); assert.equal(calls, 2);
});
