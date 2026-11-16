import { AvatarPolicyError } from "./avatar-policy-state.mjs";
import { CommunityError, communityPolicy, communityCoordinate, distanceMeters } from "./community-domain.mjs";
import { publicUUID, recordIdentity } from "./public-record-schema.mjs";

/** Request-local metadata only. A version is a selection hint, never authorization or an asset URL.
 * Parent records must still pass their own final guard. Every actual pixel read is authorized anew. */
export class CommunityAvatarReferences {
  #policy; #state; #enabled; #clock;
  constructor({ avatarPolicy, communityState, isEnabled, clock = Date.now } = {}) {
    if (typeof avatarPolicy?.readPublication !== "function" || typeof avatarPolicy.assertReadPublication !== "function" ||
        typeof communityState?.visible !== "function" || typeof communityState.assertActive !== "function" ||
        typeof isEnabled !== "function" || typeof clock !== "function") throw new CommunityError();
    this.#policy = avatarPolicy; this.#state = communityState; this.#enabled = isEnabled; this.#clock = clock;
  }
  #publication(action) {
    try { return action(); }
    catch (error) { if (error instanceof AvatarPolicyError && error.code === "AVATAR_STALE") return null; throw new CommunityError(); }
  }
  async prepare({ lease, ownerIDs, coordinate, presenceItems } = {}) {
    if (this.#enabled() !== true) return undefined;
    if (typeof lease?.check !== "function" || typeof lease.current !== "function" || typeof lease.lookup !== "function" ||
        typeof lease.accountID !== "string" || !publicUUID.test(lease.accountID) || !Array.isArray(ownerIDs) || ownerIDs.length > 100 ||
        new Set(ownerIDs).size !== ownerIDs.length || ownerIDs.some(id => typeof id !== "string" || !publicUUID.test(id)) ||
        presenceItems !== undefined && !(presenceItems instanceof Map)) throw new CommunityError("COMMUNITY_INPUT");
    const position = coordinate === undefined ? undefined : Object.freeze(communityCoordinate(coordinate));
    const started = this.#clock(), publications = new Map(), presences = new Map(), pointers = new Map();
    const check = () => {
      lease.check(); this.#state.assertActive(lease.accountID);
      const now = this.#clock();
      if (!Number.isSafeInteger(started) || started < 0 || !Number.isSafeInteger(now) || now < started) throw new CommunityError();
      return now;
    };
    check();
    for (const id of ownerIDs) {
      const value = this.#publication(() => this.#policy.readPublication(id));
      if (value) publications.set(id, value);
    }
    const peers = [...publications.keys()].filter(id => id !== lease.accountID);
    if (position) {
      if (presenceItems) {
        for (const id of peers) if (presenceItems.has(id)) presences.set(id, presenceItems.get(id));
      } else for (let i = 0; i < peers.length; i += 25) {
        check(); if (this.#enabled() !== true) return undefined;
        for (const item of await lease.lookup(peers.slice(i, i + 25).map(id => recordIdentity(id, "presence", "singleton").recordName), "presence"))
          presences.set(item.context.accountID, item);
      }
    }
    const eligible = id => {
      const now = check();
      if (id === lease.accountID) return true;
      const item = presences.get(id);
      return !!position && !!item && item.context.accountID === id && item.context.kind === "presence" && lease.current(item) &&
        item.input.active === 1 && item.record.fields.expiresAt.value > now && this.#state.visible(lease.accountID, item.context) &&
        distanceMeters(position, item.input) <= communityPolicy.radius;
    };
    const selected = [...publications].filter(([id]) => eligible(id));
    for (let i = 0; i < selected.length; i += 25) {
      check(); if (this.#enabled() !== true) return undefined;
      for (const item of await lease.lookup(selected.slice(i, i + 25).map(([, value]) => value.pointer.recordName), "avatarprofile"))
        pointers.set(item.context.accountID, item);
    }
    check();
    // Synchronous after the outer checkpoint. Never replace a captured publication with a newer one.
    return id => {
      check(); if (this.#enabled() !== true) return null;
      const publication = publications.get(id), pointer = pointers.get(id);
      if (!publication || !pointer || !eligible(id) || !this.#publication(() => this.#policy.assertReadPublication(publication)) ||
          pointer.context.accountID !== id || pointer.context.kind !== "avatarprofile" || !lease.current(pointer) ||
          pointer.record.recordChangeTag !== publication.pointerTag || pointer.input.versionID !== publication.versionID ||
          pointer.input.generation !== publication.generation) return null;
      return publication.versionID;
    };
  }
}
