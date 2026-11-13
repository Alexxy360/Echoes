import { AppleIdentityError } from "./apple-identity.mjs";
import { AppleOAuthError } from "./apple-oauth.mjs";
import { AuthenticationStateError } from "./authentication-state.mjs";

/** Internal composition only. Long-lived renewal proofs are never accepted as ordinary access tokens. */
export class SessionRenewalCoordinator {
  #state; #vault; #verifier; #apple;
  constructor({ state, credentialVault, verifier, appleClient } = {}) {
    if (typeof state?.claimRenewal !== "function" || typeof state.completeRenewal !== "function" ||
        typeof state.failRenewal !== "function" || typeof state.stageRenewalCredential !== "function" || typeof credentialVault?.open !== "function" ||
        typeof credentialVault.seal !== "function" || typeof verifier?.verifyRefresh !== "function" ||
        typeof appleClient?.validateRefreshToken !== "function") throw new AuthenticationStateError();
    this.#state = state; this.#vault = credentialVault; this.#verifier = verifier; this.#apple = appleClient;
  }
  async renew(renewalToken) {
    let context;
    try {
      context = await this.#state.claimRenewal(renewalToken);
      if (!context.needsAppleCheck) return await this.#state.completeRenewal(context.leaseID);
      const refreshToken = this.#vault.open(context.sealedCredential, {
        credentialID: context.credentialID, subjectHash: context.subjectHash,
      });
      const response = await this.#apple.validateRefreshToken(refreshToken);
      const identity = await this.#verifier.verifyRefresh(response?.identityToken, { expectedSubjectHash: context.subjectHash });
      // A newly returned credential gets its own AAD/UUID; the old ciphertext remains for explicit revocation/retention.
      const replacementCredential = response.refreshToken !== undefined && response.refreshToken !== refreshToken ?
        this.#vault.seal(response.refreshToken, { credentialID: context.replacementCredentialID, subjectHash: context.subjectHash }) : undefined;
      if (replacementCredential !== undefined) await this.#state.stageRenewalCredential(context.leaseID, {
        appleSubject: identity.appleSubject, sealedCredential: replacementCredential,
      });
      return await this.#state.completeRenewal(context.leaseID, {
        appleSubject: identity.appleSubject, identityExpiresAt: identity.expiresAt, replacementStaged: replacementCredential !== undefined,
      });
    } catch (error) {
      if (context) {
        try { await this.#state.failRenewal(context.leaseID, {
          providerRejected: error instanceof AppleOAuthError && error.code === "TOKEN_REJECTED",
        }); } catch { throw new AuthenticationStateError(); }
      }
      if (error instanceof AuthenticationStateError) throw error;
      if (error instanceof AppleIdentityError) throw new AuthenticationStateError(error.code);
      throw new AuthenticationStateError("REAUTH_REQUIRED");
    }
  }
}
