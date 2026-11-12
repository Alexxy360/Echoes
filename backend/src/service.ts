import { getAuth } from "firebase-admin/auth";
import {
  FieldPath,
  Firestore,
  Timestamp,
  Query,
  DocumentSnapshot,
} from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { geohashQueryBounds } from "geofire-common";
import {
  approximate,
  coordinate,
  cursor,
  descending,
  distance,
  encodeCursor,
  hash,
  identifier,
  InvalidInput,
  isExpired,
  mergePage,
  moderate,
  object,
  Ordered,
  policy,
  text,
  Coordinate,
} from "./domain";

type Stored = Record<string, unknown>;
type Candidate = Ordered & { data: Stored };
const collections = {
  accounts: "communityAccounts",
  presence: "communityPresence",
  messages: "communityMessages",
  reports: "communityReports",
};

export class CommunityService {
  constructor(
    private readonly db: Firestore,
    private readonly now: () => number = Date.now,
  ) {}

  private async account(uid: string): Promise<Stored> {
    const data =
      (await this.db.collection(collections.accounts).doc(uid).get()).data() ??
      {};
    if (data.suspended === true || data.deleting === true)
      throw new HttpsError("permission-denied", "Konto jest niedostępne.");
    return data;
  }

  private async rate(
    uid: string,
    key: string,
    interval: number,
  ): Promise<Stored> {
    const ref = this.db.collection(collections.accounts).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const data = (await tx.get(ref)).data() ?? {};
      if (data.suspended === true || data.deleting === true)
        throw new HttpsError("permission-denied", "Konto jest niedostępne.");
      const now = this.now();
      if (typeof data[key] === "number" && now - data[key] < interval) {
        throw new HttpsError(
          "resource-exhausted",
          "Zbyt wiele prób. Poczekaj chwilę i spróbuj ponownie.",
        );
      }
      tx.set(ref, { [key]: now }, { merge: true });
      return data;
    });
  }

  async configuration(uid: string): Promise<Stored> {
    await this.account(uid);
    const support = process.env.SUPPORT_URL ?? "";
    return {
      supportURL: /^(https:\/\/|mailto:)/.test(support) ? support : null,
      schemaVersion: 2,
    };
  }

  private async filterText(value: string): Promise<void> {
    const config = (
      await this.db.doc("communityConfiguration/moderation").get()
    ).data();
    const phrases = Array.isArray(config?.blockedPhrases)
      ? config.blockedPhrases
          .filter((x: unknown): x is string => typeof x === "string")
          .slice(0, 100)
      : [];
    moderate(value, phrases);
  }

  async publish(uid: string, input: unknown): Promise<Stored> {
    const data = object(input),
      location = approximate(coordinate(data.coordinate));
    const name = text(data.name, policy.nameLimit);
    const song = data.lastSong === "" ? "" : text(data.lastSong, 300);
    const songID =
      typeof data.appleMusicID === "string" &&
      /^[0-9]{1,30}$/.test(data.appleMusicID)
        ? data.appleMusicID
        : "";
    await this.filterText(name);
    const now = this.now();
    const measuredAt = data.measuredAt;
    if (
      typeof measuredAt !== "number" ||
      !Number.isFinite(measuredAt) ||
      measuredAt < now - 60_000 ||
      measuredAt > now + 5_000
    )
      throw new InvalidInput("Pozycja jest nieaktualna.");
    const accountRef = this.db.collection(collections.accounts).doc(uid);
    const presenceRef = this.db.collection(collections.presence).doc(uid);
    await this.db.runTransaction(async (tx) => {
      const account = (await tx.get(accountRef)).data() ?? {};
      if (account.suspended === true || account.deleting === true)
        throw new HttpsError("permission-denied", "Konto jest niedostępne.");
      if (
        typeof account.lastPresenceAt === "number" &&
        now - account.lastPresenceAt < 5_000
      )
        throw new HttpsError(
          "resource-exhausted",
          "Poczekaj chwilę przed kolejną aktualizacją.",
        );
      // A stop increments the generation. Delayed publish requests cannot restore visibility.
      const generation =
        typeof account.presenceGeneration === "number"
          ? account.presenceGeneration
          : 0;
      if (data.generation !== generation)
        throw new HttpsError(
          "failed-precondition",
          "Widoczność została zmieniona. Odśwież sesję.",
        );
      tx.set(accountRef, { lastPresenceAt: now }, { merge: true });
      tx.set(presenceRef, {
        name,
        latitude: location.latitude,
        longitude: location.longitude,
        geohash: hash(location),
        lastSong: song,
        appleMusicID: songID,
        updatedAt: Timestamp.fromMillis(now),
        expiresAt: Timestamp.fromMillis(now + policy.presenceTTL),
      });
    });
    return { expiresAt: now + policy.presenceTTL };
  }

  async visibility(uid: string): Promise<Stored> {
    const account = await this.account(uid);
    return {
      generation:
        typeof account.presenceGeneration === "number"
          ? account.presenceGeneration
          : 0,
    };
  }

  async stopSharing(uid: string): Promise<Stored> {
    const ref = this.db.collection(collections.accounts).doc(uid);
    return this.db.runTransaction(async (tx) => {
      const data = (await tx.get(ref)).data() ?? {};
      const generation =
        (typeof data.presenceGeneration === "number"
          ? data.presenceGeneration
          : 0) + 1;
      tx.set(ref, { presenceGeneration: generation }, { merge: true });
      tx.delete(this.db.collection(collections.presence).doc(uid));
      return { generation };
    });
  }

  private async blockedFor(
    uid: string,
    candidates: string[],
    account: Stored,
  ): Promise<Set<string>> {
    const blocked = new Set<string>(
      Array.isArray(account.blockedIDs) ? account.blockedIDs : [],
    );
    const ids = [...new Set(candidates)].filter(
      (id) => id !== uid && !blocked.has(id),
    );
    if (ids.length) {
      const docs = await this.db.getAll(
        ...ids.map((id) => this.db.collection(collections.accounts).doc(id)),
      );
      for (const doc of docs) {
        const data = doc.data();
        if (
          data?.suspended === true ||
          data?.deleting === true ||
          (Array.isArray(data?.blockedIDs) && data.blockedIDs.includes(uid))
        )
          blocked.add(doc.id);
      }
    }
    return blocked;
  }

  async nearby(uid: string, input: unknown): Promise<Stored> {
    const location = coordinate(object(input).coordinate),
      now = this.now();
    const account = await this.rate(uid, "lastNearbyAt", 3_000);
    const bounds = geohashQueryBounds(
      [location.latitude, location.longitude],
      policy.radius,
    );
    const snapshots = await Promise.all(
      bounds.map(([start, end]) =>
        this.db
          .collection(collections.presence)
          .orderBy("geohash")
          .startAt(start)
          .endAt(end)
          .limit(policy.maxScanned + 1)
          .get(),
      ),
    );
    const profiles = new Map<string, Stored>();
    let scanned = 0;
    for (const snapshot of snapshots) {
      scanned += snapshot.size;
      if (scanned > policy.maxScanned)
        throw new HttpsError(
          "resource-exhausted",
          "Okolica jest bardzo zatłoczona. Spróbuj ponownie później.",
        );
      for (const doc of snapshot.docs) {
        const data = doc.data();
        const expiresAt =
          data.expiresAt instanceof Timestamp ? data.expiresAt.toMillis() : 0;
        if (doc.id === uid || isExpired(expiresAt, now)) continue;
        try {
          const position = coordinate(data);
          if (distance(location, position) > policy.radius) continue;
          profiles.set(doc.id, {
            id: doc.id,
            name: text(data.name, policy.nameLimit),
            coordinate: position,
            lastSong:
              typeof data.lastSong === "string"
                ? data.lastSong.slice(0, 300)
                : "",
            appleMusicID:
              typeof data.appleMusicID === "string" ? data.appleMusicID : "",
            expiresAt,
          });
        } catch (error) {
          if (!(error instanceof InvalidInput)) throw error;
        }
      }
    }
    const blocked = await this.blockedFor(uid, [...profiles.keys()], account);
    const users = [...profiles.values()]
      .filter((value) => !blocked.has(value.id as string))
      .sort(
        (a, b) =>
          distance(location, a.coordinate as Coordinate) -
          distance(location, b.coordinate as Coordinate),
      )
      .slice(0, 100);
    return { users, serverTime: now };
  }

  private visibleMessage(
    doc: DocumentSnapshot,
    location: Coordinate,
    now: number,
    blocked: Set<string>,
  ): Candidate | undefined {
    const data = doc.data();
    if (
      !data ||
      !(data.createdAt instanceof Timestamp) ||
      !(data.expiresAt instanceof Timestamp) ||
      isExpired(data.expiresAt.toMillis(), now) ||
      data.moderationStatus !== "visible" ||
      blocked.has(data.senderID)
    )
      return undefined;
    try {
      if (distance(location, coordinate(data)) > policy.radius)
        return undefined;
      text(data.text, policy.textLimit);
      text(data.senderName, policy.nameLimit);
      identifier(data.senderID);
      return {
        id: doc.id,
        timestamp: data.createdAt.toMillis(),
        geohash: text(data.geohash, 12),
        data,
      };
    } catch (error) {
      if (error instanceof InvalidInput) return undefined;
      throw error;
    }
  }

  private publicMessage(candidate: Candidate): Stored {
    return {
      id: candidate.id,
      text: candidate.data.text,
      senderName: candidate.data.senderName,
      senderID: candidate.data.senderID,
      timestamp: candidate.timestamp,
      expiresAt: (candidate.data.expiresAt as Timestamp).toMillis(),
    };
  }

  async messages(uid: string, input: unknown): Promise<Stored> {
    const data = object(input),
      location = coordinate(data.coordinate),
      pageCursor = cursor(data.cursor);
    const now = this.now(),
      account = await this.rate(uid, "lastMessagesAt", 1_000);
    const bounds = geohashQueryBounds(
      [location.latitude, location.longitude],
      policy.radius,
    );
    // Only bounded regional queries. Each stream is paged until enough *local* messages survive filtering.
    const ownBlocked = new Set<string>(
      Array.isArray(account.blockedIDs) ? account.blockedIDs : [],
    );
    let scanned = 0;
    const batches = await Promise.all(
      bounds.map(async ([start, end]) => {
        let query: Query = this.db
          .collection(collections.messages)
          .where("geohash", ">=", start)
          .where("geohash", "<=", end)
          .where(
            "createdAt",
            ">",
            Timestamp.fromMillis(now - policy.messageTTL),
          )
          .orderBy("createdAt", "desc")
          .orderBy("geohash", "asc")
          .orderBy(FieldPath.documentId(), "desc");
        if (pageCursor)
          query = query.startAfter(
            Timestamp.fromMillis(pageCursor.timestamp),
            pageCursor.geohash,
            pageCursor.id,
          );
        const local: Candidate[] = [];
        while (local.length < policy.pageSize + 1) {
          const snapshot = await query.limit(100).get();
          scanned += snapshot.size;
          if (scanned > policy.maxScanned)
            throw new HttpsError(
              "resource-exhausted",
              "Za dużo wiadomości w okolicy. Spróbuj ponownie później.",
            );
          const blocked = await this.blockedFor(
            uid,
            snapshot.docs
              .map((doc) => doc.data().senderID)
              .filter((id): id is string => typeof id === "string"),
            account,
          );
          for (const doc of snapshot.docs) {
            const message = this.visibleMessage(doc, location, now, blocked);
            if (message) local.push(message);
          }
          if (snapshot.size < 100) break;
          query = query.startAfter(snapshot.docs[snapshot.docs.length - 1]);
        }
        return local;
      }),
    );
    const merged = mergePage(batches, policy.pageSize + 1);
    const selected = merged.slice(0, policy.pageSize);
    const knownIDs = Array.isArray(data.knownIDs)
      ? data.knownIDs.slice(0, 200).map(identifier)
      : [];
    const knownDocs = knownIDs.length
      ? await this.db.getAll(
          ...knownIDs.map((id) =>
            this.db.collection(collections.messages).doc(id),
          ),
        )
      : [];
    const reverseBlocked = await this.blockedFor(
      uid,
      knownDocs
        .map((doc) => doc.data()?.senderID)
        .filter((id): id is string => typeof id === "string"),
      account,
    );
    for (const id of reverseBlocked) ownBlocked.add(id);
    const removedIDs = knownDocs
      .filter((doc) => !this.visibleMessage(doc, location, now, ownBlocked))
      .map((doc) => doc.id);
    return {
      messages: selected
        .sort(descending)
        .reverse()
        .map((item) => this.publicMessage(item)),
      nextCursor:
        merged.length > policy.pageSize
          ? encodeCursor(merged[policy.pageSize - 1])
          : null,
      removedIDs,
      serverTime: now,
    };
  }

  async send(uid: string, input: unknown): Promise<Stored> {
    const data = object(input),
      location = approximate(coordinate(data.coordinate));
    const messageText = text(data.text, policy.textLimit),
      name = text(data.name, policy.nameLimit);
    const requestID = identifier(data.requestID);
    if (requestID.length > 64)
      throw new InvalidInput("Nieprawidłowy identyfikator próby wysłania.");
    await this.filterText(messageText);
    await this.filterText(name);
    const now = this.now(),
      messageRef = this.db
        .collection(collections.messages)
        .doc(`${uid}_${requestID}`);
    const accountRef = this.db.collection(collections.accounts).doc(uid);
    const message = await this.db.runTransaction(async (tx) => {
      const [accountDoc, existing] = await Promise.all([
        tx.get(accountRef),
        tx.get(messageRef),
      ]);
      const account = accountDoc.data() ?? {};
      if (account.suspended === true || account.deleting === true)
        throw new HttpsError("permission-denied", "Konto jest niedostępne.");
      if (existing.exists) {
        const old = existing.data()!;
        if (old.text !== messageText || old.senderName !== name)
          throw new HttpsError(
            "already-exists",
            "Ta próba wysłania ma już inną treść.",
          );
        return old;
      }
      if (
        typeof account.lastSentAt === "number" &&
        now - account.lastSentAt < 5_000
      )
        throw new HttpsError(
          "resource-exhausted",
          "Możesz wysłać jedną wiadomość co 5 sekund.",
        );
      const stored = {
        text: messageText,
        senderName: name,
        senderID: uid,
        latitude: location.latitude,
        longitude: location.longitude,
        geohash: hash(location),
        createdAt: Timestamp.fromMillis(now),
        expiresAt: Timestamp.fromMillis(now + policy.messageTTL),
        moderationStatus: "visible",
      };
      tx.set(accountRef, { lastSentAt: now }, { merge: true });
      tx.create(messageRef, stored);
      return stored;
    });
    return this.publicMessage({
      id: messageRef.id,
      timestamp: message.createdAt.toMillis(),
      geohash: message.geohash,
      data: message,
    });
  }

  async block(uid: string, input: unknown): Promise<Stored> {
    const data = object(input),
      target = identifier(data.userID);
    if (target === uid) throw new InvalidInput("Nie możesz zablokować siebie.");
    await this.rate(uid, "lastBlockAt", 1_000);
    const ref = this.db.collection(collections.accounts).doc(uid);
    await this.db.runTransaction(async (tx) => {
      const account = (await tx.get(ref)).data() ?? {};
      const ids = new Set<string>(
        Array.isArray(account.blockedIDs) ? account.blockedIDs : [],
      );
      if (data.blocked === false) ids.delete(target);
      else ids.add(target);
      if (ids.size > 200)
        throw new HttpsError(
          "resource-exhausted",
          "Osiągnięto limit listy blokad.",
        );
      tx.set(ref, { blockedIDs: [...ids] }, { merge: true });
    });
    return {};
  }

  async blockedUsers(uid: string): Promise<Stored> {
    const account = await this.account(uid);
    return {
      userIDs: Array.isArray(account.blockedIDs) ? account.blockedIDs : [],
    };
  }

  async report(uid: string, input: unknown): Promise<Stored> {
    const data = object(input),
      messageID = identifier(data.messageID),
      reason = text(data.reason, 500);
    await this.rate(uid, "lastReportAt", 10_000);
    const ref = this.db.collection(collections.messages).doc(messageID),
      message = await ref.get();
    if (
      !message.exists ||
      isExpired(
        (message.data()?.expiresAt as Timestamp)?.toMillis() ?? 0,
        this.now(),
      )
    )
      throw new HttpsError("not-found", "Wiadomość nie jest już dostępna.");
    await this.db
      .collection(collections.reports)
      .doc(`${uid}_${messageID}`)
      .set({
        reporterID: uid,
        messageID,
        reason,
        status: "open",
        createdAt: Timestamp.fromMillis(this.now()),
        expiresAt: Timestamp.fromMillis(this.now() + 30 * 86_400_000),
      });
    return {};
  }

  async deleteOwnData(uid: string): Promise<Stored> {
    const accountRef = this.db.collection(collections.accounts).doc(uid);
    // The tombstone prevents concurrent send/publish from recreating data during deletion.
    await accountRef.set({ deleting: true }, { merge: true });
    await this.db.collection(collections.presence).doc(uid).delete();
    for (const [collection, field] of [
      [collections.messages, "senderID"],
      [collections.reports, "reporterID"],
    ]) {
      while (true) {
        const docs = await this.db
          .collection(collection)
          .where(field, "==", uid)
          .limit(400)
          .get();
        if (docs.empty) break;
        const batch = this.db.batch();
        for (const doc of docs.docs) batch.delete(doc.ref);
        await batch.commit();
      }
    }
    // Retain an access-denying tombstone, without pseudonym, location or block list.
    await accountRef.set({
      deleting: true,
      expiresAt: Timestamp.fromMillis(this.now() + 86_400_000),
    });
    await getAuth().deleteUser(uid);
    return {};
  }
}
