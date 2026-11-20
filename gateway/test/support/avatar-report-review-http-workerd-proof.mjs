import { randomBytes } from "node:crypto";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { decodeAvatarReportReviewInspection } from "../../src/avatar-report-review-http.mjs";
import { digest } from "../../src/public-record-schema.mjs";

export async function avatarReportReviewHTTPWorkerdProof(p, storage, provider, assetFetch, metrics) {
  const clock = () => p.now, secret = () => randomBytes(32).toString("base64url");
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(p.now + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_REPORT_REVIEW_ENABLED: "1", AVATAR_REPORT_REVIEWER_IDS_JSON: JSON.stringify([p.operatorID]),
    AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]', CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
    CLOUDKIT_KEY_ID: "synthetic-public-v1", CLOUDKIT_PRIVATE_KEY: p.privateKeyPEM, APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: p.signInPrivateKeyPEM,
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
  const runtimeOptions = { clock, fetchImplementation: request => new URL(request.url).origin === "https://api.apple-cloudkit.com" ? provider(request) : assetFetch(request) };
  let runtime = createGatewayRuntime(storage, env, runtimeOptions);
  const id = { toString: () => "synthetic-photo-report-review-http-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw Error("Unexpected synthetic authority"); return id; }, get(value) {
    if (value !== id) throw Error("Unexpected synthetic object"); return { fetch: req => handleAuthorityRequest(req, { runtime, env, objectID: id, clock }) };
  } };
  const call = async (action, body, token = p.operatorToken) => {
    const req = new Request("https://synthetic-photo-report-review.invalid/v1/moderation/avatar-reports/" + action, { method: "POST", headers: {
      "Content-Type": "application/json", Authorization: "Bearer " + token, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify(body) });
    Object.defineProperty(req, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(req, env, { clock });
  };
  const foreign = await call("queue", { after: null }, p.foreignToken); await foreign.body?.cancel();
  const queueResponse = await call("queue", { after: null }), queue = await queueResponse.json();
  const response = await call("inspect", { reportID: p.reportID });
  if (response.status !== 200) throw Error("Synthetic HTTP inspection failed");
  const bytes = new Uint8Array(await response.arrayBuffer()); let inspection = decodeAvatarReportReviewInspection(bytes, { reportID: p.reportID }, clock());
  const exactImage = digest(inspection.image) === p.imageSHA256 && inspection.metadata.reason === p.reason;
  inspection.image.fill(0); bytes.fill(0);
  let input = { inspectionID: inspection.metadata.inspectionID, decisionID: crypto.randomUUID(), verdict: "hide_photo" };
  let retirement;
  if (p.retirement === true) {
    const query = { reportID: p.reportID, decisionID: input.decisionID, verdict: input.verdict, contentHash: inspection.metadata.contentHash };
    const before = await (await call("recover", query)).json(), closedResponse = await call("retire", query), closed = await closedResponse.json();
    runtime = createGatewayRuntime(storage, env, runtimeOptions);
    const recovered = await (await call("recover", query)).json(), late = await call("decide", input); await late.body?.cancel();
    retirement = { unconfirmedBefore: before.outcome === "not-applied", retired: closedResponse.status === 200 && closed.outcome === "retired", recovered: recovered.outcome === "retired",
      lateBlocked: late.status === 409, noEffect: storage.sql.exec("SELECT ready FROM avatar_profiles_v1 WHERE account_id=?", p.authorID).toArray()[0]?.ready === 1 };
    const next = await call("inspect", { reportID: p.reportID }), bytes = new Uint8Array(await next.arrayBuffer());
    inspection = decodeAvatarReportReviewInspection(bytes, { reportID: p.reportID }, clock()); inspection.image.fill(0); bytes.fill(0);
    input = { inspectionID: inspection.metadata.inspectionID, decisionID: crypto.randomUUID(), verdict: "hide_photo" };
  }
  const decidedResponse = await call("decide", input), decided = await decidedResponse.json();
  const replayResponse = await call("decide", input), replay = await replayResponse.json();
  runtime = createGatewayRuntime(storage, env, runtimeOptions); p.now += 90001;
  const recoveredResponse = await call("recover", { reportID: p.reportID, decisionID: input.decisionID, verdict: input.verdict, contentHash: inspection.metadata.contentHash }), recovered = await recoveredResponse.json();
  const remaining = await (await call("queue", { after: null })).json();
  env.AVATAR_REPORT_REVIEW_ENABLED = "0"; const disabled = await call("queue", { after: null }); await disabled.body?.cancel();
  return Response.json({ ...(retirement ? { retirement } : {}), ordinaryDenied: foreign.status === 403, queued: queue.items.length, exactImage,
    privateFrame: response.headers.get("Cache-Control") === "private, no-store" && response.headers.get("X-Content-Type-Options") === "nosniff",
    exactReplay: decidedResponse.status === 200 && replayResponse.status === 200 && JSON.stringify(decided) === JSON.stringify(replay),
    confirmedAfterRecreationAndExpiry: recoveredResponse.status === 200 && recovered.outcome === "confirmed" && recovered.revision === decided.revision,
    closedQueue: remaining.items.length === 0, disabled: disabled.status === 503, ...metrics(),
    actualSQL: storage.sql.exec("SELECT COUNT(*) AS n FROM avatar_report_decisions_v1").toArray()[0].n === 1 });
}
