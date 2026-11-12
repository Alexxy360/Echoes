import { distanceBetween, geohashForLocation } from "geofire-common";

export const policy = Object.freeze({
  radius: 3000,
  presenceTTL: 600_000,
  messageTTL: 7_200_000,
  pageSize: 50,
  maxScanned: 5000,
  nameLimit: 40,
  textLimit: 500,
});
export type Coordinate = { latitude: number; longitude: number };

export class InvalidInput extends Error {}

export function coordinate(input: unknown): Coordinate {
  const data = object(input);
  const latitude = data.latitude,
    longitude = data.longitude;
  if (
    typeof latitude !== "number" ||
    typeof longitude !== "number" ||
    !Number.isFinite(latitude) ||
    !Number.isFinite(longitude) ||
    Math.abs(latitude) > 90 ||
    Math.abs(longitude) > 180
  ) {
    throw new InvalidInput("Nieprawidłowa pozycja.");
  }
  return { latitude, longitude };
}

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new InvalidInput("Nieprawidłowe dane.");
  return value as Record<string, unknown>;
}

export function text(value: unknown, limit: number): string {
  if (typeof value !== "string") throw new InvalidInput("Nieprawidłowy tekst.");
  const result = value.normalize("NFC").trim();
  if (
    !result.length ||
    result.length > limit ||
    /[\x00-\x08\x0b-\x1f\x7f\u202a-\u202e\u2066-\u2069]/u.test(result)
  ) {
    throw new InvalidInput(`Tekst musi zawierać od 1 do ${limit} znaków.`);
  }
  return result;
}

export function identifier(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,512}$/.test(value))
    throw new InvalidInput("Nieprawidłowy identyfikator.");
  return value;
}

// Constant latitude spacing; longitude spacing adapts to latitude. No raw GPS is persisted.
export function approximate(value: Coordinate): Coordinate {
  const latitude = Math.max(
    -89.999,
    Math.min(89.999, Math.round(value.latitude / 0.0045) * 0.0045),
  );
  const step = Math.min(
    180,
    0.0045 / Math.max(0.000025, Math.cos((latitude * Math.PI) / 180)),
  );
  let longitude = Math.round(value.longitude / step) * step;
  longitude = ((((longitude + 180) % 360) + 360) % 360) - 180;
  return { latitude, longitude };
}

export function hash(value: Coordinate): string {
  return geohashForLocation([value.latitude, value.longitude]);
}

export function distance(a: Coordinate, b: Coordinate): number {
  return (
    distanceBetween([a.latitude, a.longitude], [b.latitude, b.longitude]) * 1000
  );
}

export type Ordered = { id: string; timestamp: number; geohash: string };
export function descending(a: Ordered, b: Ordered): number {
  return (
    b.timestamp - a.timestamp ||
    (a.geohash < b.geohash ? -1 : a.geohash > b.geohash ? 1 : 0) ||
    (a.id < b.id ? 1 : a.id > b.id ? -1 : 0)
  );
}

export function mergePage<T extends Ordered>(
  batches: T[][],
  limit: number,
): T[] {
  return [...new Map(batches.flat().map((item) => [item.id, item])).values()]
    .sort(descending)
    .slice(0, limit);
}

export function isExpired(expiresAt: number, now: number): boolean {
  return !Number.isFinite(expiresAt) || expiresAt <= now;
}

export function moderate(value: string, customPatterns: string[] = []): void {
  const normalized = value
    .normalize("NFKC")
    .replace(/[\u200b-\u200d\ufeff]/g, "")
    .toLowerCase();
  // Conservative baseline; server-managed literal phrases can extend it without shipping a new app.
  const prohibited = [
    "kill yourself",
    "zabij się",
    "zabij sie",
    ...customPatterns,
  ];
  if (
    prohibited.some(
      (phrase) =>
        phrase.length > 0 && normalized.includes(phrase.toLowerCase()),
    ) ||
    /(.)\1{29}/u.test(normalized)
  )
    throw new InvalidInput(
      "Treść została zatrzymana przez filtr bezpieczeństwa.",
    );
}

export function cursor(value: unknown): Ordered | undefined {
  if (value == null) return undefined;
  if (typeof value !== "string" || value.length > 1024)
    throw new InvalidInput("Nieprawidłowa strona.");
  try {
    const parsed = object(
      JSON.parse(Buffer.from(value, "base64url").toString("utf8")),
    );
    const id = identifier(parsed.id);
    const geohash = text(parsed.geohash, 12);
    if (!/^[0123456789bcdefghjkmnpqrstuvwxyz]+$/.test(geohash))
      throw new Error();
    if (
      typeof parsed.timestamp !== "number" ||
      !Number.isFinite(parsed.timestamp) ||
      parsed.timestamp < 0
    )
      throw new Error();
    return { id, timestamp: parsed.timestamp, geohash };
  } catch {
    throw new InvalidInput("Nieprawidłowa strona.");
  }
}

export function encodeCursor(value: Ordered): string {
  return Buffer.from(
    JSON.stringify({
      id: value.id,
      timestamp: value.timestamp,
      geohash: value.geohash,
    }),
  ).toString("base64url");
}
