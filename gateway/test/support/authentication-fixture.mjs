import { DatabaseSync } from "node:sqlite";
import { createHash, generateKeyPairSync, randomBytes, randomUUID, sign } from "node:crypto";
import { AuthenticationState, AuthenticationStateError } from "../../src/authentication-state.mjs";
import { AppleLoginCoordinator } from "../../src/apple-login.mjs";
import { AppleIdentityTokenVerifier } from "../../src/apple-identity.mjs";
import { ApplePublicKeySource } from "../../src/apple-public-keys.mjs";
import { RefreshCredentialVault } from "../../src/refresh-credential-vault.mjs";
import { SessionRenewalCoordinator } from "../../src/session-renewal.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";

export const hash = value => createHash("sha256").update(value).digest("hex");
export const start = 1794603600000;
const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicKey = { ...pair.publicKey.export({ format: "jwk" }), kid: "synthetic-login-key", alg: "RS256", use: "sig" };
export const syntheticCode = "SYNTHETIC-PRIVATE-CODE";
export const syntheticRefresh = "SYNTHETIC-PRIVATE-REFRESH";
export function fixture({ path = ":memory:", syncHook = async () => {}, sqlHook = () => {}, credentialVault, renewalProofs } = {}) {
  const db = new DatabaseSync(path); let now = start; let syncCount = 0;
  const storage = {
    sql: { exec(sql, ...bindings) {
      sqlHook(sql); const rows = db.prepare(sql).all(...bindings); return { toArray: () => rows };
    } },
    transactionSync(action) {
      db.exec("BEGIN IMMEDIATE");
      try { const result = action(); db.exec("COMMIT"); return result; }
      catch (error) { db.exec("ROLLBACK"); throw error; }
    },
    async sync() { await syncHook(++syncCount); },
  };
  const clock = () => now;
  const proofs = renewalProofs ?? new RenewalProofs({ activeKeyID: "test", keys: { test: randomBytes(32).toString("base64url") } });
  const state = new AuthenticationState(storage, { clock, renewalProofs: proofs });
  const keys = new ApplePublicKeySource({ clock, fetchImplementation: async () => Response.json({ keys: [publicKey] }) });
  const verifier = new AppleIdentityTokenVerifier({ keySource: keys, clock });
  const vault = credentialVault ?? new RefreshCredentialVault({ activeKeyID: "test-v1", keys: { "test-v1": randomBytes(32).toString("base64url") } });
  const result = { db, state, storage, clock, verifier, vault, proofs, publicJWK: publicKey, advance(ms) { now += ms; }, close() { db.close(); },
    token(challenge, subject = "synthetic.user", lifetime = 3600) {
      const header = Buffer.from(JSON.stringify({ kid: publicKey.kid, alg: "RS256" })).toString("base64url");
      const body = Buffer.from(JSON.stringify({ iss: "https://appleid.apple.com", aud: "mpvEcho.Echo",
        sub: subject, ...(challenge ? { nonce: hash(challenge.nonce) } : {}), iat: Math.floor(now / 1000) - 1,
        exp: Math.floor(now / 1000) + lifetime, email: "PRIVATE-SYNTHETIC@example.invalid" })).toString("base64url");
      return header + "." + body + "." + sign("RSA-SHA256", Buffer.from(header + "." + body), pair.privateKey).toString("base64url");
    },
    coordinator(exchange) { return new AppleLoginCoordinator({ state, verifier, credentialVault: vault,
      exchangeAuthorizationCode: async input => ({ identityToken: await exchange(input), refreshToken: syntheticRefresh }) }); },
    renewal(validateRefreshToken = async () => ({ identityToken: result.token(null) })) {
      return new SessionRenewalCoordinator({ state, verifier, credentialVault: vault, appleClient: { validateRefreshToken } });
    },
    async challenge(budget = hash("synthetic-transport-budget")) { return state.issueChallenge(budget); },
    async session(subject = "synthetic.user", lifetime = 3600) {
      const challenge = await state.issueChallenge(hash(randomUUID()));
      const idToken = result.token(challenge, subject, lifetime);
      return result.coordinator(async () => idToken).login({ challengeID: challenge.challengeID,
        identityToken: idToken, authorizationCode: syntheticCode });
    },
  };
  return result;
}
export const codeIs = code => error => error instanceof AuthenticationStateError && error.code === code &&
  error.message === "Authentication request could not be completed." && error.cause === undefined;
