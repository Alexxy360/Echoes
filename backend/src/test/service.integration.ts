import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { CommunityService } from "../service";
import { approximate, hash, policy } from "../domain";

const project = "demo-echoes";
if (
  process.env.FIRESTORE_EMULATOR_HOST !== "127.0.0.1:8080" &&
  process.env.FIRESTORE_EMULATOR_HOST !== "localhost:8080"
) {
  throw new Error("Integration tests require the local demo-echoes emulator.");
}
initializeApp({ projectId: project });
const db = getFirestore();
let now = Date.now();
const service = new CommunityService(db, () => now);
const center = { latitude: 51.11, longitude: 17.03 };
const far = { latitude: 52.23, longitude: 21.01 };

beforeEach(async () => {
  const result = await fetch(
    `http://127.0.0.1:8080/emulator/v1/projects/${project}/databases/(default)/documents`,
    { method: "DELETE" },
  );
  assert.ok(result.ok);
  now = Date.now();
});

async function seedMessage(
  id: string,
  age: number,
  location = center,
  senderID = "other",
  moderationStatus = "visible",
) {
  const point = approximate(location);
  await db
    .doc(`communityMessages/${id}`)
    .set({
      senderID,
      senderName: "Gość",
      text: `Wiadomość ${id}`,
      latitude: point.latitude,
      longitude: point.longitude,
      geohash: hash(point),
      moderationStatus,
      createdAt: Timestamp.fromMillis(now - age),
      expiresAt: Timestamp.fromMillis(now - age + policy.messageTTL),
    });
}

test("regional pagination returns fresh local messages beyond 100 unrelated posts", async () => {
  await Promise.all(
    Array.from({ length: 110 }, (_, i) =>
      seedMessage(`remote${i}`, 100_000 + i, far),
    ),
  );
  await Promise.all(
    Array.from({ length: 125 }, (_, i) =>
      seedMessage(`local${String(i).padStart(3, "0")}`, 1000 + i),
    ),
  );
  const page = (await service.messages("viewer", { coordinate: center })) as {
    messages: { id: string }[];
    nextCursor: string;
  };
  assert.equal(page.messages.length, 50);
  assert.equal(page.messages[49].id, "local000");
  assert.ok(page.messages.every((x) => x.id.startsWith("local")));
  now += 1100;
  const second = (await service.messages("viewer", {
    coordinate: center,
    cursor: page.nextCursor,
  })) as { messages: { id: string }[] };
  assert.equal(second.messages.length, 50);
  assert.ok(
    second.messages.every((x) => !page.messages.some((y) => x.id === y.id)),
  );
  assert.ok(!JSON.stringify(page).includes("latitude"));
});

test("expired, moderated and blocked posts are removed, including cached IDs", async () => {
  await seedMessage("expired", policy.messageTTL + 1);
  await seedMessage("hidden", 500, center, "bad", "hidden");
  await seedMessage("blocked", 600, center, "blocked-author");
  await seedMessage("reverseBlocked", 700, center, "reverse-author");
  await seedMessage("allowed", 800);
  await db
    .doc("communityAccounts/viewer")
    .set({ blockedIDs: ["blocked-author"] });
  await db
    .doc("communityAccounts/reverse-author")
    .set({ blockedIDs: ["viewer"] });
  const result = (await service.messages("viewer", {
    coordinate: center,
    knownIDs: ["expired", "hidden", "blocked", "reverseBlocked"],
  })) as { messages: { id: string }[]; removedIDs: string[] };
  assert.deepEqual(
    result.messages.map((x) => x.id),
    ["allowed"],
  );
  assert.equal(result.removedIDs.length, 4);
});

test("send is idempotent and enforces server rate limits", async () => {
  const data = {
    coordinate: center,
    name: "Gość",
    text: "Hej",
    requestID: "request-one",
  };
  const first = await service.send("sender", data);
  const retry = await service.send("sender", data);
  assert.deepEqual(retry, first);
  assert.equal((await db.collection("communityMessages").get()).size, 1);
  await assert.rejects(
    service.send("sender", { ...data, requestID: "request-two" }),
    /5 sekund/,
  );
  await assert.rejects(
    service.send("sender", { ...data, text: "Inna treść" }),
    /inną treść/,
  );
  const stored = (
    await db.collection("communityMessages").get()
  ).docs[0].data();
  assert.notEqual(stored.latitude, center.latitude);
  assert.ok(!("senderId" in stored));
});

test("publishing requires current location and old generations cannot restore stopped presence", async () => {
  const input = {
    coordinate: center,
    name: "Gość",
    lastSong: "Utwór",
    appleMusicID: "123",
    generation: 0,
    measuredAt: now,
  };
  await service.publish("viewer", input);
  await service.stopSharing("viewer");
  now += 6000;
  await assert.rejects(
    service.publish("viewer", { ...input, measuredAt: now }),
    /Widoczność została zmieniona/,
  );
  assert.equal((await db.doc("communityPresence/viewer").get()).exists, false);
  await assert.rejects(
    service.publish("viewer", {
      ...input,
      generation: 1,
      measuredAt: now - 61_000,
    }),
    /nieaktualna/,
  );
});

test("nearby omits expired and remote profiles before producing a bounded response", async () => {
  for (const [uid, position, expiry] of [
    ["local", center, now + 60_000],
    ["far", far, now + 60_000],
    ["old", center, now - 1],
  ] as const) {
    const point = approximate(position);
    await db
      .doc(`communityPresence/${uid}`)
      .set({
        ...point,
        name: "Gość",
        geohash: hash(point),
        lastSong: "",
        appleMusicID: "",
        expiresAt: Timestamp.fromMillis(expiry),
      });
  }
  const result = (await service.nearby("viewer", { coordinate: center })) as {
    users: { id: string }[];
  };
  assert.deepEqual(
    result.users.map((x) => x.id),
    ["local"],
  );
});

test("callables require authentication and direct Firestore requests are denied", async () => {
  const root = `http://127.0.0.1:5001/${project}/europe-west1`;
  const denied = await fetch(root + "/communityConfig", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ data: {} }),
  });
  assert.equal(denied.status, 401);
  const signup = await fetch(
    "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-key",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const user = (await signup.json()) as { idToken: string; localId: string };
  assert.ok(user.idToken);
  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${user.idToken}`,
  };
  const config = await fetch(root + "/communityConfig", {
    method: "POST",
    headers,
    body: JSON.stringify({ data: {} }),
  });
  assert.equal(config.status, 200);
  const direct = await fetch(
    `http://127.0.0.1:8080/v1/projects/${project}/databases/(default)/documents/communityMessages`,
    { headers },
  );
  assert.equal(direct.status, 403);
  const forged = await fetch(
    `http://127.0.0.1:8080/v1/projects/${project}/databases/(default)/documents/communityPresence/forged`,
    {
      method: "PATCH",
      headers,
      body: JSON.stringify({ fields: { name: { stringValue: "Fake" } } }),
    },
  );
  assert.equal(forged.status, 403);
});

test("authenticated callable flow binds sender to token and deletes only its own data", async () => {
  const signup = await fetch(
    "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-key",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ returnSecureToken: true }),
    },
  );
  const user = (await signup.json()) as { idToken: string; localId: string };
  async function call(name: string, data: unknown = {}) {
    return fetch(`http://127.0.0.1:5001/${project}/europe-west1/${name}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${user.idToken}`,
      },
      body: JSON.stringify({ data }),
    });
  }
  const publish = await call("communityPublish", {
    coordinate: center,
    name: "Gość",
    lastSong: "",
    appleMusicID: "",
    generation: 0,
    measuredAt: Date.now(),
  });
  assert.equal(publish.status, 200);
  const sent = await call("communitySend", {
    coordinate: center,
    name: "Gość",
    text: "Własna wiadomość",
    senderID: "forged-sender",
    requestID: "callable-request",
  });
  assert.equal(sent.status, 200);
  const result = (await sent.json()) as {
    result: { id: string; senderID: string };
  };
  assert.equal(result.result.senderID, user.localId);
  assert.ok(!JSON.stringify(result).includes("latitude"));
  await seedMessage("someoneElse", 2000);
  const deleted = await call("communityDeleteOwnData");
  assert.equal(deleted.status, 200);
  assert.equal(
    (await db.doc(`communityMessages/${result.result.id}`).get()).exists,
    false,
  );
  assert.equal(
    (await db.doc(`communityPresence/${user.localId}`).get()).exists,
    false,
  );
  assert.equal(
    (await db.doc("communityMessages/someoneElse").get()).exists,
    true,
  );
  assert.equal(
    (await db.doc(`communityAccounts/${user.localId}`).get()).data()?.deleting,
    true,
  );
});
