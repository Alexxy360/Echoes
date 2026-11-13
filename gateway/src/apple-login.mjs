import { AppleIdentityError } from "./apple-identity.mjs";
import { AuthenticationStateError } from "./authentication-state.mjs";
import { appleSubjectHash } from "./refresh-credential-vault.mjs";

/** No default code-exchange stub. A trusted real Apple adapter is mandatory before any HTTP wiring. */
export class AppleLoginCoordinator {
  #state; #verifier; #exchange; #vault;
  constructor({ state, verifier, exchangeAuthorizationCode, credentialVault } = {}) {
    if (!state || typeof verifier?.verify !== "function" || typeof exchangeAuthorizationCode !== "function" ||
        typeof credentialVault?.seal !== "function") {
      throw new AuthenticationStateError();
    }
    this.#state = state; this.#verifier = verifier; this.#exchange = exchangeAuthorizationCode; this.#vault = credentialVault;
  }

  async login({ challengeID, identityToken, authorizationCode } = {}) {
    try {
      if (typeof authorizationCode !== "string" || !/^[\x21-\x7e]{1,2048}$/.test(authorizationCode)) {
        throw new AuthenticationStateError("INVALID_IDENTITY");
      }
      const challenge = await this.#state.beginVerification(challengeID);
      const identity = await this.#verifier.verify(identityToken, challenge);
      await this.#state.claimChallenge(challengeID, challenge.expectedNonce);
      let exchanged;
      try {
        exchanged = await this.#exchange({ authorizationCode });
      } catch { throw new AuthenticationStateError("EXCHANGE_UNAVAILABLE"); }
      const exchangedIdentity = await this.#verifier.verify(exchanged?.identityToken, challenge);
      const sealedCredential = this.#vault.seal(exchanged.refreshToken, {
        credentialID: challengeID, subjectHash: appleSubjectHash(exchangedIdentity.appleSubject),
      });
      await this.#state.stageRefreshCredential(challengeID, {
        appleSubject: exchangedIdentity.appleSubject, sealedCredential,
      });
      if (identity.appleSubject !== exchangedIdentity.appleSubject) throw new AuthenticationStateError("INVALID_IDENTITY");
      return await this.#state.completeLogin(challengeID, {
        appleSubject: identity.appleSubject,
        identityExpiresAt: Math.min(identity.expiresAt, exchangedIdentity.expiresAt),
      });
    } catch (error) {
      if (error instanceof AuthenticationStateError) throw error;
      if (error instanceof AppleIdentityError) throw new AuthenticationStateError(error.code);
      throw new AuthenticationStateError();
    }
  }
}
