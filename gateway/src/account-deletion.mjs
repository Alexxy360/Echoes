import { AppleIdentityError } from "./apple-identity.mjs";
import { RefreshCredentialError } from "./refresh-credential-vault.mjs";
import { AuthenticationStateError } from "./authentication-state.mjs";

/** Fresh Apple proof specifically bound to deletion; no new refresh token is needed to honor erasure. */
export class AccountDeletionCoordinator {
  #authentication; #deletions; #verifier;
  constructor({ authenticationState, deletionState, verifier } = {}) {
    if (typeof authenticationState?.startVerifiedDeletion !== "function" || typeof verifier?.verify !== "function" ||
        typeof deletionState?.lookupStatus !== "function") throw new AuthenticationStateError("DELETION_UNAVAILABLE");
    this.#authentication = authenticationState; this.#deletions = deletionState; this.#verifier = verifier;
  }
  async request({ challengeID, identityToken, deletionID, statusToken, expectedAccountID } = {}) {
    try {
      const ticket = { deletionID, statusToken }, existing = this.#deletions.lookupStatus(ticket);
      if (existing) return existing; // Narrow recovery capability; it cannot start or alter another deletion.
      const purpose = { purpose: "account_deletion" };
      const challenge = await this.#authentication.beginVerification(challengeID, purpose);
      const identity = await this.#verifier.verify(identityToken, challenge);
      await this.#authentication.claimChallenge(challengeID, challenge.expectedNonce, purpose);
      await this.#authentication.startVerifiedDeletion(challengeID, { appleSubject: identity.appleSubject,
        identityExpiresAt: identity.expiresAt, deletionID, statusToken, expectedAccountID });
      return this.#deletions.status(ticket);
    } catch (error) {
      if (error instanceof AuthenticationStateError) throw error;
      if (error instanceof AppleIdentityError) throw new AuthenticationStateError(error.code);
      throw new AuthenticationStateError("DELETION_UNAVAILABLE");
    }
  }
}

/** Bounded internal job step. The real, owner-scoped CloudKit erasure adapter is mandatory, with no stub success. */
export class AccountDeletionProcessor {
  #state; #vault; #apple; #erase; #timeout;
  constructor({ deletionState, credentialVault, appleClient, erasePublicDataBatch, eraseTimeoutMilliseconds = 10000 } = {}) {
    if (typeof deletionState?.claimPublicBatch !== "function" || typeof credentialVault?.open !== "function" ||
        typeof appleClient?.revokeRefreshToken !== "function" || typeof erasePublicDataBatch !== "function" ||
        !Number.isInteger(eraseTimeoutMilliseconds) || eraseTimeoutMilliseconds < 1 || eraseTimeoutMilliseconds > 10000) {
      throw new AuthenticationStateError("DELETION_UNAVAILABLE");
    }
    this.#state = deletionState; this.#vault = credentialVault; this.#apple = appleClient; this.#erase = erasePublicDataBatch;
    this.#timeout = eraseTimeoutMilliseconds;
  }
  async #eraseBatch(context) {
    const controller = new AbortController(); let timer;
    try {
      const deadline = new Promise((_, reject) => { timer = setTimeout(() => {
        controller.abort(); reject(new AuthenticationStateError("DELETION_UNAVAILABLE"));
      }, this.#timeout); });
      return await Promise.race([Promise.resolve().then(() => this.#erase({ ...context, maximumRecords: 100, signal: controller.signal })), deadline]);
    } finally { clearTimeout(timer); controller.abort(); }
  }
  async step(deletionID) {
    const data = await this.#state.claimPublicBatch(deletionID);
    if (data) {
      try {
        const receipt = await this.#eraseBatch(data);
        await this.#state.completePublicBatch(data, receipt);
      } catch { await this.#state.failPublicBatch(data.leaseID); }
    }
    const credential = await this.#state.claimRevocation(deletionID);
    if (credential) {
      try {
        const token = this.#vault.open(credential.sealedCredential, {
          credentialID: credential.credentialID, subjectHash: credential.subjectHash,
        });
        await this.#apple.revokeRefreshToken(token);
        await this.#state.completeRevocation(credential);
      } catch (error) {
        await this.#state.failRevocation(credential.leaseID, { permanent: error instanceof RefreshCredentialError });
      }
    }
    return this.#state.finalize(deletionID);
  }
}
