import { createHash, timingSafeEqual } from "node:crypto";

export function jsonResponse(value, status = 200, extra = {}) {
  return Response.json(value, { status, headers: {
    "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...extra,
  } });
}

export function activeProbeConfiguration(env, now = Date.now()) {
  if (env.PROBE_ENABLED !== "1" || env.CLOUDKIT_CONTAINER !== "iCloud.mpvEcho.Echo" ||
      env.CLOUDKIT_ENVIRONMENT !== "development" ||
      !/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(env.PROBE_RUN_ID ?? "") ||
      !/^[A-Za-z0-9_-]{43}$/.test(env.PROBE_BEARER_TOKEN ?? "")) return null;
  const deadline = Date.parse(env.PROBE_EXPIRES_AT ?? "");
  if (!Number.isFinite(deadline) || deadline <= now || deadline > now + 2 * 60 * 60 * 1000) return null;
  return { runID: env.PROBE_RUN_ID, deadline };
}

function authorized(header, token) {
  if (typeof header !== "string" || header.length > 256) return false;
  const actual = createHash("sha256").update(header).digest();
  const expected = createHash("sha256").update("Bearer " + token).digest();
  return timingSafeEqual(actual, expected);
}

async function emptyBody(request) {
  const reader = request.body?.getReader();
  if (!reader) return false;
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Input timeout")), 3000); });
  let size = 0;
  const bytes = [];
  try {
    while (true) {
      const { done, value } = await Promise.race([reader.read(), timeout]);
      if (done) break;
      size += value.byteLength;
      if (size > 64) return false;
      bytes.push(...value);
    }
    return new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array(bytes)).trim() === "{}";
  } catch { return false; }
  finally {
    clearTimeout(timer);
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

/** Developer diagnostic only; this token is not end-user authentication. */
export async function handleDevelopmentProbe(request, env, invokeGate, now = Date.now()) {
  const url = new URL(request.url);
  if (url.pathname === "/health" && request.method === "GET" && !url.search) {
    return jsonResponse({ status: "ok", mode: "development-diagnostic" });
  }
  if (url.pathname !== "/probe" || url.search) return jsonResponse({ error: "not-found" }, 404);
  if (request.method !== "POST") return jsonResponse({ error: "method-not-allowed" }, 405, { Allow: "POST" });
  const config = activeProbeConfiguration(env, now);
  if (!config) return jsonResponse({ error: "diagnostic-disabled" }, 503);
  if (!authorized(request.headers.get("Authorization"), env.PROBE_BEARER_TOKEN)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  if (!/^application\/json(?:\s*;|$)/i.test(request.headers.get("Content-Type") ?? "") ||
      !(await emptyBody(request))) return jsonResponse({ error: "invalid-input" }, 400);
  try {
    const response = await invokeGate(config.runID);
    if (!(response instanceof Response) ||
        !/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "")) {
      return jsonResponse({ error: "diagnostic-unavailable" }, 503);
    }
    const headers = new Headers(response.headers);
    headers.set("Cache-Control", "no-store");
    headers.set("X-Content-Type-Options", "nosniff");
    headers.delete("Access-Control-Allow-Origin");
    return new Response(response.body, { status: response.status, headers });
  }
  catch { return jsonResponse({ error: "diagnostic-unavailable" }, 503); }
}
