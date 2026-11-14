import { createHmac } from "node:crypto";
import { isIP } from "node:net";
import { base64URLBytes } from "./apple-public-keys.mjs";

export class GatewayLimitError extends Error {
  constructor(code = "LIMIT_UNAVAILABLE", retryAfterSeconds = 60) {
    super("Gateway request limit is unavailable.");
    this.code = ["RATE_LIMITED", "CAPACITY_LIMITED"].includes(code) ? code : "LIMIT_UNAVAILABLE";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}
function networkIdentity(ip) {
  if (typeof ip !== "string" || ip.length > 64) throw new GatewayLimitError();
  if (isIP(ip) === 4) return "v4:" + ip;
  if (isIP(ip) !== 6) throw new GatewayLimitError();
  const canonical = new URL("http://[" + ip + "]/").hostname.slice(1, -1);
  const halves = canonical.split("::"), left = halves[0] ? halves[0].split(":") : [], right = halves[1] ? halves[1].split(":") : [];
  const words = (halves.length === 2 ? [...left, ...Array(8 - left.length - right.length).fill("0"), ...right] : left)
    .map(value => Number.parseInt(value, 16));
  if (words.length !== 8 || words.some(value => !Number.isInteger(value))) throw new GatewayLimitError();
  if (words.slice(0, 5).every(value => value === 0) && words[5] === 65535) {
    return "v4:" + [words[6] >> 8, words[6] & 255, words[7] >> 8, words[7] & 255].join(".");
  }
  return "v6/64:" + words.slice(0, 4).map(value => value.toString(16).padStart(4, "0")).join(":");
}

/** Only the edge Worker supplies the platform IP; never derive this from client JSON or forwarding headers. */
export function edgeBudgetHash(ip, secret, now = Date.now()) {
  try {
    const key = base64URLBytes(secret, 32);
    if (key.length !== 32 || !Number.isSafeInteger(now) || now < 0) throw new Error();
    return createHmac("sha256", key).update("echoes/edge-budget/v1\0" + Math.floor(now / 86400000) + "\0" + networkIdentity(ip)).digest("hex");
  } catch { throw new GatewayLimitError(); }
}

export class GatewayLimits {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function") throw new GatewayLimitError();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => {
      storage.sql.exec(`CREATE TABLE IF NOT EXISTS gateway_daily_v1(day INTEGER PRIMARY KEY,requests INTEGER NOT NULL,heavy INTEGER NOT NULL)`);
      storage.sql.exec(`CREATE TABLE IF NOT EXISTS gateway_windows_v1(kind TEXT NOT NULL,key_hash TEXT NOT NULL,
        window_start INTEGER NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(kind,key_hash,window_start))`);
      storage.sql.exec("CREATE INDEX IF NOT EXISTS gateway_window_expiry_v1 ON gateway_windows_v1(window_start)");
    });
  }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch { throw new GatewayLimitError(); } }
  #rows(sql, ...bindings) { return this.#storage.sql.exec(sql, ...bindings).toArray(); }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw new GatewayLimitError(); return now; }
  async #sync() { try { await this.#storage.sync(); } catch { throw new GatewayLimitError(); } }
  async consume(serverBudgetHash, { heavy = false } = {}) {
    if (typeof serverBudgetHash !== "string" || !/^[a-f0-9]{64}$/.test(serverBudgetHash) || typeof heavy !== "boolean") throw new GatewayLimitError();
    const now = this.#now(), day = Math.floor(now / 86400000), minute = Math.floor(now / 60000) * 60000;
    const outcome = this.#tx(() => {
      const daily = this.#rows(`INSERT INTO gateway_daily_v1(day,requests,heavy) VALUES (?,1,0)
        ON CONFLICT(day) DO UPDATE SET requests=requests+1 WHERE requests<2000 RETURNING heavy`, day)[0];
      if (!daily) return new GatewayLimitError("RATE_LIMITED", Math.max(1, Math.ceil(((day + 1) * 86400000 - now) / 1000)));
      this.#storage.sql.exec(`DELETE FROM gateway_windows_v1 WHERE (kind,key_hash,window_start) IN
        (SELECT kind,key_hash,window_start FROM gateway_windows_v1 WHERE window_start<? LIMIT 20)`, minute);
      for (const [kind, ceiling] of heavy ? [["network", 120], ["heavy", 12]] : [["network", 120]]) {
        // At most two new windows/request, bounded by the persistent 2000/day counter.
        // Expired-window removal outpaces new inserts; no full-table COUNT scan per request.
        const allowed = this.#rows(`INSERT INTO gateway_windows_v1(kind,key_hash,window_start,count) VALUES (?,?,?,1)
          ON CONFLICT(kind,key_hash,window_start) DO UPDATE SET count=count+1 WHERE count<? RETURNING count`, kind, serverBudgetHash, minute, ceiling);
        if (!allowed.length) return new GatewayLimitError("RATE_LIMITED", Math.max(1, Math.ceil((minute + 60000 - now) / 1000)));
      }
      if (heavy) {
        const allowed = this.#rows("UPDATE gateway_daily_v1 SET heavy=heavy+1 WHERE day=? AND heavy<300 RETURNING heavy", day);
        if (!allowed.length) return new GatewayLimitError("RATE_LIMITED", Math.max(1, Math.ceil(((day + 1) * 86400000 - now) / 1000)));
      }
    });
    await this.#sync(); if (outcome) throw outcome;
  }
  async purgeExpired() {
    const now = this.#now(), day = Math.floor(now / 86400000), minute = Math.floor(now / 60000) * 60000;
    this.#tx(() => {
      this.#storage.sql.exec(`DELETE FROM gateway_windows_v1 WHERE (kind,key_hash,window_start) IN
        (SELECT kind,key_hash,window_start FROM gateway_windows_v1 WHERE window_start<? LIMIT 100)`, minute);
      this.#storage.sql.exec("DELETE FROM gateway_daily_v1 WHERE day IN (SELECT day FROM gateway_daily_v1 WHERE day<? LIMIT 100)", day - 1);
    });
    await this.#sync();
  }
}
