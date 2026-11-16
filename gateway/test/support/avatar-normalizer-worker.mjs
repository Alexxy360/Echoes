import { DurableObject } from "cloudflare:workers";
import { normalizedAvatarManifest } from "../../src/avatar-normalizer.mjs";
import { createWorkerAvatarNormalizer } from "../../src/avatar-codecs-workerd.mjs";

// Local integration harness only. No gateway secrets, publication, Apple fetch or user identity.
export class AvatarCodecTestAuthority extends DurableObject {
  #normalizer = createWorkerAvatarNormalizer(() => true);
  async fetch(request) {
    try {
      if (request.method !== "POST") return new Response(null, { status: 405 });
      // The fixture server is loopback-only; this is not the production binary intake endpoint.
      const bytes = new Uint8Array(await request.arrayBuffer());
      const result = await this.#normalizer.prepare({ bytes,
        versionID: "64000000-0000-4000-8000-000000000002", requestID: "64000000-0000-4000-8000-000000000003",
        authorize: () => ({ accountID: "64000000-0000-4000-8000-000000000001" }) });
      const sqlAvailable = this.ctx.storage.sql.exec("SELECT 1 AS value").toArray()[0]?.value === 1;
      return Response.json({ image: normalizedAvatarManifest(result, "image"), thumbnail: normalizedAvatarManifest(result, "thumbnail"), sqlAvailable },
        { headers: { "Cache-Control": "no-store" } });
    } catch (error) { return Response.json({ error: error.code ?? "UNAVAILABLE" }, { status: 400 }); }
  }
}
export default { fetch(request, env) { return env.CODEC.get(env.CODEC.idFromName("synthetic-only")).fetch(request); } };
