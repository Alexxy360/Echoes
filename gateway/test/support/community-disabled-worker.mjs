import worker from "../../src/community-worker.mjs";
export { CommunityAuthority } from "../../src/community-worker.mjs";

// Loopback harness has plain HTTP. Model only the platform HTTPS URL; production inspection stays on.
export default { fetch(request, env, ctx) {
  const incoming = new URL(request.url);
  return worker.fetch(new Request("https://synthetic-disabled.invalid" + incoming.pathname + incoming.search, request), env, ctx);
} };
