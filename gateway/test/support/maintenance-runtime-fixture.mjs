import { generateKeyPairSync, randomBytes } from "node:crypto";
import { publicFixture, messageInput, syntheticPublicKeyConfiguration } from "./public-record-fixture.mjs";
import { RefreshCredentialVault } from "../../src/refresh-credential-vault.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { createGatewayRuntime } from "../../src/gateway-runtime.mjs";

/** Synthetic keys and signed protocol model only. No Apple/Cloudflare network access. */
export async function maintenanceRuntimeFixture({ at, ...options } = {}) {
  const refresh = randomBytes(32).toString("base64url"), renewal = randomBytes(32).toString("base64url");
  const f = await publicFixture({ ...options,
    credentialVault: new RefreshCredentialVault({ activeKeyID: "v1", keys: { v1: refresh } }),
    renewalProofs: new RenewalProofs({ activeKeyID: "v1", keys: { v1: renewal } }),
  });
  if (at !== undefined) f.advance(at - f.clock());
  const signedIn = await f.session();
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development",
    GATEWAY_EXPIRES_AT: new Date(f.clock() + 6 * 86400000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", PUBLIC_RETENTION_ENABLED: "0", COMMUNITY_ENABLED: "0",
    CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development", ...syntheticPublicKeyConfiguration(),
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: generateKeyPairSync("ec", { namedCurve: "prime256v1" })
      .privateKey.export({ type: "pkcs8", format: "pem" }),
    REFRESH_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: refresh }),
    RENEWAL_ACTIVE_KEY_ID: "v1", RENEWAL_KEYS_JSON: JSON.stringify({ v1: renewal }), REQUEST_BUDGET_KEY: randomBytes(32).toString("base64url") };
  let alarm = null, appleCalls = 0, onApple;
  f.storage.getAlarm = async () => alarm;
  f.storage.setAlarm = async value => { alarm = value; };
  f.storage.deleteAlarm = async () => { alarm = null; };
  const fetchImplementation = async (request, options) => {
    if (new URL(request.url).origin === "https://api.apple-cloudkit.com") return f.model.fetch(request, options);
    if (request.url !== "https://appleid.apple.com/auth/revoke") throw new Error("Unexpected synthetic provider route");
    appleCalls++; return await onApple?.(request, options) ?? new Response(null, { status: 200 });
  };
  const result = { ...f, env, signedIn, alarm: () => alarm,
    counts: () => ({ records: f.model.requests.length, checkpoint: f.model.checkpointRequests.length, apple: appleCalls }),
    interceptApple(hook) { onApple = hook; },
    activate(changes = {}) { Object.assign(env, changes); return createGatewayRuntime(f.storage, env, { clock: f.clock, fetchImplementation }); },
    async message(session = signedIn) { const input = messageInput(session); return { input, record: await f.repository.write(input) }; },
    budget: () => f.db.prepare("SELECT total,deletion,retention FROM maintenance_daily_v1 ORDER BY day DESC LIMIT 1").get(),
  };
  return result;
}
