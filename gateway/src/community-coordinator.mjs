import { CommunityError, CommunityCursor, communityPolicy as policy, objectFields, communityUUID, communityText,
  communityCoordinate, moderationPhrases, moderateText, supportAddress, distanceMeters, messageName, laterMessage, beforeCursor } from "./community-domain.mjs";
import { inputHash, normalizePublicInput } from "./public-record-schema.mjs";

export const communityActions = Object.freeze(["config", "visibility", "publish", "stop", "nearby", "messages", "send", "block", "block/state", "blocked", "report", "profile", "profile/save"]);
/** Functional server boundary. Finalizers run synchronously AFTER the outer remote checkpoint. */
export class CommunityCoordinator {
  #state; #authentication; #repository; #clock; #cursor; #phrases; #support; #avatars;
  constructor({ state, authentication, repository, avatarReferences, cursorSecret, clock = Date.now, phrasesJSON = "[]", supportURL = "" } = {}) {
    if (typeof state?.begin !== "function" || typeof authentication?.authorize !== "function" || typeof repository?.beginRead !== "function") throw new CommunityError();
    if (avatarReferences !== undefined && typeof avatarReferences?.prepare !== "function") throw new CommunityError();
    this.#state = state; this.#authentication = authentication; this.#repository = repository; this.#clock = clock;
    this.#avatars = avatarReferences;
    this.#cursor = new CommunityCursor(cursorSecret, { clock }); this.#phrases = moderationPhrases(phrasesJSON); this.#support = supportAddress(supportURL);
  }
  #identity(token, accountID, signal) {
    if (signal?.aborted) throw new CommunityError();
    const identity = this.#authentication.authorize(token);
    if (accountID !== undefined && identity.accountID !== accountID) throw new CommunityError("COMMUNITY_STALE");
    this.#state.assertActive(identity.accountID); return identity;
  }
  #text(value, maximum) { const result = communityText(value, maximum); moderateText(result, this.#phrases); return result; }
  #readable(lease, item, coordinate) {
    return lease.current(item) && this.#state.visible(lease.accountID, item.context) && item.record.fields.expiresAt.value > this.#clock() &&
      (item.context.kind !== "presence" || item.input.active === 1) && distanceMeters(coordinate, item.input) <= policy.radius;
  }
  #message(item) { return { id: item.context.recordName, authorID: item.context.accountID, name: item.input.name,
    text: item.input.text, timestamp: item.context.createdAt, expiresAt: item.record.fields.expiresAt.value }; }
  async prepare(action, body, { accessToken, signal } = {}) {
    if (!communityActions.includes(action)) throw new CommunityError("COMMUNITY_INPUT");
    const accountID = this.#identity(accessToken, undefined, signal).accountID;
    const check = () => this.#identity(accessToken, accountID, signal);
    const result = build => () => { check(); return { ...build(), serverTime: this.#clock() }; };
    if (action === "config") {
      objectFields(body, []); return result(() => ({ radiusMeters: policy.radius, presenceLifetimeSeconds: 600,
        messageLifetimeSeconds: 7200, messagePageSize: policy.pageSize, supportURL: this.#support }));
    }
    if (action === "visibility") { objectFields(body, []); return result(() => this.#state.visibility(accountID)); }
    if (action === "blocked") { objectFields(body, []); return result(() => ({ accountIDs: this.#state.blocked(accountID) })); }
    if (action === "block/state") { objectFields(body, ["accountID"]); communityUUID(body.accountID); return result(() => this.#state.blockState(accountID, body.accountID)); }
    if (action === "profile" || action === "profile/save") {
      if (action === "profile/save") {
        objectFields(body, ["requestID", "name", "revision"]); communityUUID(body.requestID);
        if (body.revision !== null && (typeof body.revision !== "string" || !/^[\x21-\x7e]{1,512}$/.test(body.revision))) throw new CommunityError("COMMUNITY_INPUT");
        const name = this.#text(body.name, 40);
        const receipt = await this.#repository.write({ accessToken, signal, kind: "profile", logicalID: "singleton", requestID: body.requestID,
          expectedTag: body.revision, input: { name }, authorizeMutation: check });
        return result(() => ({ name, revision: receipt.recordChangeTag }));
      }
      objectFields(body, []);
      const lease = await this.#repository.beginRead({ accessToken, signal });
      const [item] = await lease.lookup([lease.ownName("profile")], "profile");
      const avatars = await this.#avatars?.prepare({ lease, ownerIDs: item && lease.current(item) ? [accountID] : [] });
      return result(() => ({ profile: item && lease.current(item) ? { name: item.input.name, revision: item.record.recordChangeTag,
        ...(avatars ? { avatarVersionID: avatars(accountID) } : {}) } : null }));
    }
    if (action === "publish" || action === "stop" || action === "send" || action === "block") {
      const kind = { publish: "presence", stop: "presence", send: "message", block: "block" }[action];
      let input, logicalID, intent;
      if (action === "publish") {
        objectFields(body, ["requestID", "name", "coordinate", "song", "songID", "generation", "measuredAt"]);
        input = { name: this.#text(body.name, 40), ...communityCoordinate(body.coordinate), song: body.song, songID: body.songID,
          generation: body.generation, measuredAt: body.measuredAt };
        // Music metadata is public content too. Empty now-playing remains allowed.
        if (typeof input.song === "string" && input.song.length) input.song = this.#text(input.song, 300);
        logicalID = "singleton";
      } else if (action === "stop") {
        objectFields(body, ["requestID", "generation"]);
        input = { active: false, generation: body.generation + 1 }; logicalID = "singleton";
      } else if (action === "send") {
        objectFields(body, ["requestID", "name", "text", "coordinate"]);
        input = { name: this.#text(body.name, 40), text: this.#text(body.text, 500), ...communityCoordinate(body.coordinate) }; logicalID = body.requestID;
      } else {
        objectFields(body, ["requestID", "accountID", "blocked", "generation"]); communityUUID(body.accountID);
        input = { targetID: body.accountID, blocked: body.blocked }; logicalID = body.accountID;
      }
      communityUUID(body.requestID);
      const normalized = normalizePublicInput(kind, input, this.#clock()), hash = inputHash(normalized);
      if (action === "stop") intent = await this.#state.stop(accountID, body.requestID, body.generation, hash);
      else intent = await this.#state.begin({ accountID, kind, logicalID, requestID: body.requestID, payloadHash: hash,
        generation: body.generation, active: action === "block" ? body.blocked : true });
      const permit = () => { check(); this.#state.assertCurrent(intent); };
      const receipt = await this.#repository[kind === "presence" || kind === "block" ? "writeLatest" : "write"]({
        accessToken, kind, logicalID, requestID: body.requestID, input, signal, authorizeMutation: permit });
      permit(); await this.#state.finish(intent);
      return result(() => { permit(); return { id: receipt.recordName, ...(kind === "presence" ? { generation: intent.generation, visible: !!intent.active } : {}),
        ...(kind === "block" ? { generation: intent.generation, blocked: !!intent.active } : {}),
        ...(kind === "message" ? { message: { id: receipt.recordName, authorID: accountID, name: receipt.fields.name.value,
          text: receipt.fields.text.value, timestamp: receipt.fields.createdAt.value, expiresAt: receipt.fields.expiresAt.value } } : {}) }; });
    }
    if (action === "report") {
      objectFields(body, ["requestID", "messageID", "reason", "coordinate"]); communityUUID(body.requestID);
      if (typeof body.messageID !== "string" || !messageName.test(body.messageID)) throw new CommunityError("COMMUNITY_INPUT");
      const coordinate = communityCoordinate(body.coordinate), reason = communityText(body.reason, 500);
      const lease = await this.#repository.beginRead({ accessToken, signal });
      const [item] = await lease.lookup([body.messageID], "message");
      const canReport = () => { check(); if (!item || !this.#readable(lease, item, coordinate)) throw new CommunityError("COMMUNITY_NOT_FOUND"); };
      canReport(); const input = { messageID: body.messageID, reason };
      const intent = await this.#state.begin({ accountID, kind: "report", logicalID: body.requestID, requestID: body.requestID,
        payloadHash: inputHash(normalizePublicInput("report", input, this.#clock())) });
      const permit = () => { canReport(); this.#state.assertCurrent(intent); };
      await this.#repository.write({ accessToken, signal, kind: "report", logicalID: body.requestID, requestID: body.requestID, input, authorizeMutation: permit });
      permit(); await this.#state.finish(intent);
      return result(() => { this.#state.assertCurrent(intent); return { accepted: true }; });
    }
    if (action === "nearby") {
      objectFields(body, ["coordinate"]); const coordinate = communityCoordinate(body.coordinate);
      await this.#state.admitRead(accountID, "nearby");
      const lease = await this.#repository.beginRead({ accessToken, signal }), cutoff = this.#clock(), found = new Map();
      let marker = null, pages = 0;
      do {
        if (++pages > policy.maximumPages) throw new CommunityError("COMMUNITY_CAPACITY");
        const page = await lease.candidates({ kind: "presence", coordinate, cutoff, marker }); marker = page.marker;
        for (const item of await lease.lookup([...page.records.keys()], "presence")) found.set(item.context.recordName, item);
      } while (marker !== null);
      const selected = [...found.values()].filter(item => item.context.accountID !== accountID && this.#readable(lease, item, coordinate))
        .sort((a, b) => Math.round(distanceMeters(coordinate, a.input)) - Math.round(distanceMeters(coordinate, b.input)) || a.context.accountID.localeCompare(b.context.accountID)).slice(0, 100);
      const avatars = await this.#avatars?.prepare({ lease, ownerIDs: [...new Set(selected.map(item => item.context.accountID))], coordinate,
        presenceItems: new Map(selected.map(item => [item.context.accountID, item])) });
      return result(() => ({ users: selected.filter(item => this.#readable(lease, item, coordinate))
        .map(item => ({ id: item.context.accountID, name: item.input.name, latitude: item.input.latitude, longitude: item.input.longitude,
          song: item.input.song, songID: item.input.songID, updatedAt: item.context.startedAt, expiresAt: item.record.fields.expiresAt.value,
          ...(avatars ? { avatarVersionID: avatars(item.context.accountID) } : {}),
          distanceMeters: Math.round(distanceMeters(coordinate, item.input)) }))
        .sort((a, b) => a.distanceMeters - b.distanceMeters || a.id.localeCompare(b.id)).slice(0, 100) }));
    }
    objectFields(body, ["coordinate"], ["cursor", "knownIDs"]);
    const coordinate = communityCoordinate(body.coordinate), knownIDs = body.knownIDs ?? [];
    if (!Array.isArray(knownIDs) || knownIDs.length > policy.maximumKnown || new Set(knownIDs).size !== knownIDs.length ||
        knownIDs.some(id => typeof id !== "string" || !messageName.test(id))) throw new CommunityError("COMMUNITY_INPUT");
    const position = body.cursor === undefined || body.cursor === null ? this.#cursor.initial(accountID, coordinate) : this.#cursor.open(body.cursor, accountID, coordinate);
    await this.#state.admitRead(accountID, "messages");
    const lease = await this.#repository.beginRead({ accessToken, signal }), selected = new Map(), known = new Map();
    let pages = 0, pending = [...position.pending], marker = position.marker, exhausted = position.exhausted;
    while (selected.size <= policy.pageSize) {
      if (!pending.length) {
        if (exhausted) break;
        if (++pages > policy.maximumPages) throw new CommunityError("COMMUNITY_CAPACITY");
        const page = await lease.candidates({ kind: "message", coordinate, cutoff: position.cutoff, marker });
        pending = [...page.records.keys()]; marker = page.marker; exhausted = marker === null;
      }
      const batch = pending; pending = [];
      const items = new Map((await lease.lookup(batch, "message")).map(item => [item.context.recordName, item]));
      for (let i = 0; i < batch.length; i++) {
        const item = items.get(batch[i]); if (!item) continue;
        const dto = this.#message(item);
        if (dto.timestamp <= position.cutoff && beforeCursor(dto, position.last) && this.#readable(lease, item, coordinate)) selected.set(dto.id, item);
        if (selected.size > policy.pageSize) { pending = batch.slice(i); selected.delete(dto.id); break; }
      }
      if (pending.length) break;
    }
    for (let i = 0; i < knownIDs.length; i += 25) for (const item of await lease.lookup(knownIDs.slice(i, i + 25), "message")) known.set(item.context.recordName, item);
    // Encrypt before the final checkpoint; the finalizer only removes newly hidden records, never adds a newer page.
    const ordered = [...selected.values()].sort((a, b) => laterMessage(this.#message(a), this.#message(b)));
    const last = ordered.length ? this.#message(ordered.at(-1)) : position.last;
    const cursor = pending.length || !exhausted ? this.#cursor.seal({ ...position, pending, marker, exhausted,
      last: last ? { id: last.id, timestamp: last.timestamp } : null }) : null;
    const avatars = await this.#avatars?.prepare({ lease, ownerIDs: [...new Set(ordered.filter(item => this.#readable(lease, item, coordinate)).map(item => item.context.accountID))], coordinate });
    return result(() => ({ messages: ordered.filter(item => this.#readable(lease, item, coordinate)).map(item => ({ ...this.#message(item),
      ...(avatars ? { avatarVersionID: avatars(item.context.accountID) } : {}) })).reverse(), cursor,
      removedIDs: knownIDs.filter(id => !known.has(id) || !this.#readable(lease, known.get(id), coordinate)) }));
  }
}
