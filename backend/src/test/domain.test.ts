import { test } from "node:test";
import assert from "node:assert/strict";
import {
  approximate,
  coordinate,
  cursor,
  encodeCursor,
  hash,
  InvalidInput,
  isExpired,
  mergePage,
  moderate,
  text,
} from "../domain";

test("rejects malformed inputs and normalizes Unicode", () => {
  assert.throws(() => text(" \n ", 40), InvalidInput);
  assert.throws(() => text("x".repeat(501), 500), InvalidInput);
  assert.throws(() => text("hello\u202etext", 500), InvalidInput);
  assert.throws(() => text("hello\rtext", 500), InvalidInput);
  assert.equal(text("  Żółw  ", 40), "Żółw");
  assert.throws(
    () => coordinate({ latitude: NaN, longitude: 17 }),
    InvalidInput,
  );
  assert.throws(() => coordinate({ latitude: 91, longitude: 0 }), InvalidInput);
});

test("stored position is approximate, valid at poles and antimeridian", () => {
  for (const point of [
    { latitude: 51.118843, longitude: 17.015202 },
    { latitude: 90, longitude: 180 },
    { latitude: -90, longitude: -180 },
  ]) {
    const result = approximate(point);
    assert.notDeepEqual(result, point);
    assert.deepEqual(coordinate(result), result);
    assert.ok(hash(result).length > 0);
  }
});

test("merges newest records across regions before applying the page limit", () => {
  const regionA = Array.from({ length: 100 }, (_, i) => ({
    id: `a${i}`,
    timestamp: i,
    geohash: "u3",
  }));
  const freshLocal = { id: "new", timestamp: 101, geohash: "u3" };
  const result = mergePage([regionA, [freshLocal, regionA[99]]], 50);
  assert.equal(result[0].id, "new");
  assert.equal(result.length, 50);
  assert.equal(new Set(result.map((x) => x.id)).size, 50);
});

test("cursor round-trips and rejects malformed payload", () => {
  const value = { id: "message-1", timestamp: 1234, geohash: "u3h4" };
  assert.deepEqual(cursor(encodeCursor(value)), value);
  assert.throws(() => cursor("not-json"), InvalidInput);
  assert.throws(
    () =>
      cursor(
        Buffer.from(
          JSON.stringify({ ...value, timestamp: "yesterday" }),
        ).toString("base64url"),
      ),
    InvalidInput,
  );
});

test("expiry and moderation do not depend on TTL cleanup", () => {
  assert.equal(isExpired(1000, 1000), true);
  assert.equal(isExpired(1001, 1000), false);
  assert.throws(() => moderate("ZABIJ SIĘ"), InvalidInput);
  assert.throws(
    () => moderate("Offer fake invitation", ["fake invitation"]),
    InvalidInput,
  );
  assert.doesNotThrow(() => moderate("Cześć, czego słuchacie?"));
});
