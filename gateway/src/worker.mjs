import { DurableObject } from "cloudflare:workers";
import { CloudKitDevelopmentSigner } from "./cloudkit-request.mjs";
import { probeCloudKitDevelopment } from "./cloudkit-probe.mjs";
import { activeProbeConfiguration, handleDevelopmentProbe, jsonResponse } from "./probe-http.mjs";
import { runReservedProbe } from "./probe-gate.mjs";

export default {
  fetch(request, env) {
    return handleDevelopmentProbe(request, env, (runID) => {
      const id = env.DEVELOPMENT_PROBE.idFromName(runID);
      return env.DEVELOPMENT_PROBE.get(id).fetch("https://development-probe.internal/run", { method: "POST" });
    });
  },
};

export class DevelopmentProbe extends DurableObject {
  async fetch(request) {
    const config = activeProbeConfiguration(this.env);
    if (!config || request.method !== "POST" || new URL(request.url).pathname !== "/run" ||
        this.ctx.id.toString() !== this.env.DEVELOPMENT_PROBE.idFromName(config.runID).toString()) {
      return jsonResponse({ error: "diagnostic-disabled" }, 503);
    }
    // Validate credentials before reserving a run. Nothing is logged or sent to the caller.
    let signer;
    try {
      signer = new CloudKitDevelopmentSigner({
        container: this.env.CLOUDKIT_CONTAINER, environment: this.env.CLOUDKIT_ENVIRONMENT,
        keyID: this.env.CLOUDKIT_KEY_ID, privateKeyPEM: this.env.CLOUDKIT_PRIVATE_KEY,
      });
    } catch { return jsonResponse({ error: "diagnostic-disabled" }, 503); }
    return runReservedProbe(this.ctx.storage.sql, config.runID,
      (context) => probeCloudKitDevelopment(signer, fetch, context), () => this.ctx.storage.sync());
  }
}
