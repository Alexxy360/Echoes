import { DatabaseSync } from "node:sqlite";
import { constants } from "node:fs";
import { lstat, mkdtemp, open } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { digest, plain } from "../src/public-record-schema.mjs";
import { verifyCommunityProtocolPlan } from "./community-protocol-plan.mjs";

export class ProtocolJournalError extends Error {
  constructor(code = "JOURNAL_FAILED") { super("Local protocol journal unavailable."); this.code = code; }
}
function configure(db) {
  db.exec("PRAGMA busy_timeout=0; PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON; PRAGMA trusted_schema=OFF;");
  if (db.prepare("PRAGMA synchronous").get().synchronous !== 3 || db.prepare("PRAGMA journal_mode").get().journal_mode !== "delete") throw new ProtocolJournalError();
}
async function privatePath(path, directory) {
  const info = await lstat(path);
  if ((directory ? !info.isDirectory() : !info.isFile()) || info.isSymbolicLink() || (info.mode & 0o077) !== 0 ||
      typeof process.getuid === "function" && info.uid !== process.getuid() || !directory && info.size > 1024 * 1024) throw new ProtocolJournalError("JOURNAL_SCOPE");
}
async function emptyPrivateFile(path) {
  const handle = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try { await handle.sync(); } finally { await handle.close(); }
}

/** A second SQLite file holds a process lock while journal commits remain independent/durable. */
export class CommunityProtocolJournal {
  #db; #lease; #hash; #closed = false; #run = null;
  directory;
  constructor(token, directory, db, lease, hash) {
    if (token !== construct) throw new ProtocolJournalError();
    this.directory = directory; this.#db = db; this.#lease = lease; this.#hash = hash;
  }
  static async create(parentDirectory, prepared) {
    if (typeof parentDirectory !== "string" || !isAbsolute(parentDirectory)) throw new ProtocolJournalError("JOURNAL_SCOPE");
    verifyCommunityProtocolPlan(prepared?.plan, prepared?.sha256);
    const directory = await mkdtemp(join(parentDirectory, "echoes-community-protocol-"));
    // mkdtemp creates a private directory. Never adopt an arbitrary existing file as a new run.
    await privatePath(directory, true);
    await emptyPrivateFile(join(directory, "journal.sqlite")); await emptyPrivateFile(join(directory, "lease.sqlite"));
    for (const path of [directory, parentDirectory]) {
      const handle = await open(path, constants.O_RDONLY);
      try { await handle.sync(); } finally { await handle.close(); }
    }
    return this.#connect(directory, prepared.sha256, prepared);
  }
  static async open(directory, expectedSHA256) { return this.#connect(directory, expectedSHA256); }
  static async #connect(directory, expectedSHA256, prepared) {
    let db, lease;
    try {
      if (typeof directory !== "string" || !isAbsolute(directory) || !/^[a-f0-9]{64}$/.test(expectedSHA256 ?? "")) throw new ProtocolJournalError("JOURNAL_SCOPE");
      await privatePath(directory, true);
      for (const name of ["journal.sqlite", "lease.sqlite"]) await privatePath(join(directory, name), false);
      lease = new DatabaseSync(join(directory, "lease.sqlite"));
      configure(lease);
      if (prepared) lease.exec("CREATE TABLE gate(id INTEGER PRIMARY KEY CHECK(id=1)); INSERT INTO gate VALUES(1)");
      try { lease.exec("BEGIN IMMEDIATE"); } catch { throw new ProtocolJournalError("JOURNAL_BUSY"); }
      db = new DatabaseSync(join(directory, "journal.sqlite")); configure(db);
      if (prepared) {
        db.exec("CREATE TABLE snapshot(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,plan_hash TEXT NOT NULL,plan TEXT NOT NULL,state TEXT NOT NULL,state_hash TEXT NOT NULL)");
        db.prepare("INSERT INTO snapshot VALUES(1,0,?,?,?,?)").run(expectedSHA256, JSON.stringify(prepared.plan), "null", digest("0\0null"));
      }
      const result = new CommunityProtocolJournal(construct, directory, db, lease, expectedSHA256);
      result.snapshot(); return result;
    } catch (error) {
      try { db?.close(); } catch {} try { lease?.close(); } catch {}
      throw error instanceof ProtocolJournalError ? error : new ProtocolJournalError();
    }
  }
  snapshot() {
    try {
      if (this.#closed) throw new ProtocolJournalError();
      const row = this.#db.prepare("SELECT * FROM snapshot WHERE id=1").get();
      if (!row || row.plan_hash !== this.#hash || !Number.isSafeInteger(row.revision) || row.revision < 0 ||
          typeof row.state !== "string" || Buffer.byteLength(row.state) > 65536 || typeof row.plan !== "string" || Buffer.byteLength(row.plan) > 65536 ||
          row.state_hash !== digest(row.revision + "\0" + row.state)) throw new ProtocolJournalError("JOURNAL_SCOPE");
      const prepared = verifyCommunityProtocolPlan(JSON.parse(row.plan), this.#hash);
      return { ...prepared, revision: row.revision, state: JSON.parse(row.state) };
    } catch (error) { throw error instanceof ProtocolJournalError ? error : new ProtocolJournalError(); }
  }
  write(state) {
    let transaction = false;
    try {
      if (!plain(state)) throw new ProtocolJournalError("JOURNAL_SCOPE");
      const text = JSON.stringify(state);
      if (Buffer.byteLength(text) > 65536) throw new ProtocolJournalError("JOURNAL_SCOPE");
      const current = this.snapshot(), revision = current.revision + 1;
      this.#db.exec("BEGIN IMMEDIATE"); transaction = true;
      const result = this.#db.prepare("UPDATE snapshot SET revision=?,state=?,state_hash=? WHERE id=1 AND revision=? AND plan_hash=?")
        .run(revision, text, digest(revision + "\0" + text), current.revision, this.#hash);
      if (result.changes !== 1) throw new ProtocolJournalError("JOURNAL_SCOPE");
      this.#db.exec("COMMIT"); transaction = false;
      return this.snapshot();
    } catch (error) {
      if (transaction) try { this.#db.exec("ROLLBACK"); } catch {}
      throw error instanceof ProtocolJournalError ? error : new ProtocolJournalError();
    }
  }
  beginRun() {
    if (this.#closed || this.#run) throw new ProtocolJournalError("JOURNAL_BUSY");
    return this.#run = Symbol("protocol-run");
  }
  endRun(token) {
    if (!this.#run || this.#run !== token) throw new ProtocolJournalError("JOURNAL_BUSY");
    this.#run = null;
  }
  close() {
    if (this.#closed) return;
    if (this.#run) throw new ProtocolJournalError("JOURNAL_BUSY");
    this.#closed = true;
    try { this.#db.close(); } finally { this.#lease.close(); }
  }
}
const construct = Symbol("CommunityProtocolJournal");
