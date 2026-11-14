import { AppleIdentityError } from "./apple-identity.mjs";
import { AuthenticationStateError } from "./authentication-state.mjs";

/** A separate Apple nonce/purpose proves the owner of lost grants; no code exchange or new grant. */
export class SessionResetCoordinator {
  #state; #verifier;
  constructor({ state, verifier } = {}) {
    if (typeof state?.resetVerifiedSessions !== "function" || typeof verifier?.verify !== "function") throw new AuthenticationStateError();
    this.#state = state; this.#verifier = verifier;
  }
  async reset({ challengeID, identityToken, expectedAccountID } = {}) {
    try {
      const purpose = { purpose: "session_reset" };
      const challenge = await this.#state.beginVerification(challengeID, purpose);
      const identity = await this.#verifier.verify(identityToken, challenge);
      await this.#state.claimChallenge(challengeID, challenge.expectedNonce, purpose);
      await this.#state.resetVerifiedSessions(challengeID, { appleSubject: identity.appleSubject,
        identityExpiresAt: identity.expiresAt, expectedAccountID });
    } catch (error) {
      if (error instanceof AuthenticationStateError) throw error;
      if (error instanceof AppleIdentityError) throw new AuthenticationStateError(error.code);
      throw new AuthenticationStateError();
    }
  }
}
