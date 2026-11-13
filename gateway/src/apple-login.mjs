import { AppleIdentityError } from "./apple-identity.mjs";
import { AuthenticationStateError } from "./authentication-state.mjs";

/** No default code-exchange stub. A trusted real Apple adapter is mandatory before any HTTP wiring. */
export class AppleLoginCoordinator {
  #state; #verifier; #exchange;
  constructor({ state, verifier, exchangeAuthorizationCode } = {}) {
    if (!state || typeof verifier?.verify !== "function" || typeof exchangeAuthorizationCode !== "function") {
      throw new AuthenticationStateError();
    }
    this.#state = state; this.#verifier = verifier; this.#exchange = exchangeAuthorizationCode;
  }

  async login({ challengeID, identityToken, authorizationCode } = {}) {
    try {
      if (typeof authorizationCode !== "string" || !/^[\x21-\x7e]{1,2048}$/.test(authorizationCode)) {
        throw new AuthenticationStateError("INVALID_IDENTITY");
      }
      const challenge = await this.#state.beginVerification(challengeID);
      const identity = await this.#verifier.verify(identityToken, challenge);
      await this.#state.claimChallenge(challengeID, challenge.expectedNonce);
      let exchangedToken;
      try {
        // The adapter must validate Apple's response and safely handle refresh/revocation credentials.
        // No code, ID token or refresh token is stored by this coordinator.
        exchangedToken = await this.#exchange({ authorizationCode, expectedNonce: challenge.expectedNonce });
      } catch { throw new AuthenticationStateError("EXCHANGE_UNAVAILABLE"); }
      const exchangedIdentity = await this.#verifier.verify(exchangedToken, challenge);
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
