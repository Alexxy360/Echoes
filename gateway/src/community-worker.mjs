import { DurableObject } from "cloudflare:workers";
import { activeGatewayConfiguration, createGatewayRuntime, createGatewayLocalMaintenance,
  forwardGatewayRequest, handleAuthorityRequest } from "./gateway-runtime.mjs";

export default { fetch: forwardGatewayRequest };

export class CommunityAuthority extends DurableObject {
  #runtime;
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      if (!activeGatewayConfiguration(env)) return;
      try {
        // Deletion stays unavailable until the real owner-scoped CloudKit adapter is wired here.
        this.#runtime = createGatewayRuntime(ctx.storage, env);
        await this.#runtime.maintenance.schedule();
      } catch { this.#runtime = undefined; }
    });
  }
  async fetch(request) {
    return handleAuthorityRequest(request, { runtime: this.#runtime, env: this.env, objectID: this.ctx.id });
  }
  async alarm() {
    try {
      const maintenance = this.#runtime?.maintenance ?? createGatewayLocalMaintenance(this.ctx.storage);
      const processor = activeGatewayConfiguration(this.env) ? this.#runtime?.processor : undefined;
      await maintenance.alarm({ processor });
    } catch { throw new Error("Gateway maintenance is unavailable."); }
  }
}
