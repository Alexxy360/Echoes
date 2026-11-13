import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer } from "node:http";
import { once } from "node:events";
import { generateKeyPairSync } from "node:crypto";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { probeCloudKitDevelopment } from "../src/cloudkit-probe.mjs";
import { inspectDevelopmentRuntime } from "../src/runtime-check.mjs";

const privateKeyPEM = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });
const signer = new CloudKitDevelopmentSigner({ container: "iCloud.example.echoes", environment: "development",
  keyID: "synthetic-test-key", privateKeyPEM });

test("redirect never receives signed headers or retries the create at the redirect target", async () => {
  let redirectedRequests = 0;
  let originRequests = 0;
  const target = createServer((_request, response) => { redirectedRequests++; response.end("unexpected"); });
  const origin = createServer((_request, response) => {
    originRequests++;
    response.writeHead(302, { Location: `http://127.0.0.1:${target.address().port}/leak` }); response.end();
  });
  target.listen(0, "127.0.0.1"); await once(target, "listening");
  origin.listen(0, "127.0.0.1"); await once(origin, "listening");
  try {
    // Only the test transport rewrites the URL to loopback. Production always uses Apple's fixed host.
    const transport = (request, init) => fetch(new Request(`http://127.0.0.1:${origin.address().port}/`, request), init);
    const report = await probeCloudKitDevelopment(signer, transport);
    assert.equal(report.writeSucceeded, false);
    assert.equal(report.errorCode, "HTTP_302");
    assert.equal(report.cleanupErrorCode, "HTTP_302");
    assert.equal(originRequests, 2); // One create and the bounded cleanup; no retry of create.
    assert.equal(redirectedRequests, 0);
  } finally {
    origin.closeAllConnections(); target.closeAllConnections();
    await Promise.all([new Promise(r => origin.close(r)), new Promise(r => target.close(r))]);
  }
});

test("local runtime inspection returns neither signature, key nor exception message", () => {
  const report = inspectDevelopmentRuntime(signer, "e84656d0-7ef7-4e36-8767-c65e7b94a4f3");
  assert.equal(report.requestConstructed, true);
  assert.equal(report.signaturePresent, true);
  assert.equal(report.networkRequests, 0);
  assert.equal(JSON.stringify(report).includes(privateKeyPEM), false);
  const failed = inspectDevelopmentRuntime({ request() { throw new TypeError("SYNTHETIC-SECRET"); } }, "unused");
  assert.equal(failed.requestConstructed, false);
  assert.equal(failed.errorName, "TypeError");
  assert.equal(JSON.stringify(failed).includes("SYNTHETIC-SECRET"), false);
});
