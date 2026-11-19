import { constants, lstatSync, openSync, fstatSync, readSync, closeSync } from "node:fs";
import { open, link, unlink, mkdir, lstat } from "node:fs/promises";
import { isAbsolute, dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { digest } from "../src/public-record-schema.mjs";

export class CommunityProtocolCLIError extends Error {
  constructor(code = "CLI_CONFIGURATION") { super("Local Development protocol command refused or incomplete."); this.code = code; }
}
const refuse = code => { throw new CommunityProtocolCLIError(code); };
const owned = info => typeof process.getuid !== "function" || info.uid === process.getuid();
const identity = info => [info.dev, info.ino, info.uid, info.mode, info.size, info.mtimeMs, info.ctimeMs].join(":");

/** Bounded, no-follow reads. The second fstat also rejects replacement/changes during reading. */
export function readProtocolPrivateFile(path, maximumBytes) {
  let descriptor;
  try {
    if (typeof path !== "string" || !isAbsolute(path) || !Number.isInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 65536) refuse("CLI_PRIVATE_FILE");
    const initial = lstatSync(path);
    if (!initial.isFile() || initial.isSymbolicLink() || !owned(initial) || (initial.mode & 0o077) !== 0 || initial.size > maximumBytes) refuse("CLI_PRIVATE_FILE");
    descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const before = fstatSync(descriptor);
    if (identity(before) !== identity(initial)) refuse("CLI_PRIVATE_FILE");
    const buffer = Buffer.alloc(maximumBytes + 1); let count = 0;
    while (count < buffer.length) {
      const read = readSync(descriptor, buffer, count, buffer.length - count, count); if (!read) break; count += read;
    }
    if (count > maximumBytes || count !== before.size || identity(fstatSync(descriptor)) !== identity(before)) refuse("CLI_PRIVATE_FILE");
    const bytes = buffer.subarray(0, count);
    return { bytes, sha256: digest(bytes), identity: identity(before) };
  } catch (error) { throw error instanceof CommunityProtocolCLIError ? error : new CommunityProtocolCLIError("CLI_PRIVATE_FILE"); }
  finally { if (descriptor !== undefined) try { closeSync(descriptor); } catch { refuse("CLI_PRIVATE_FILE"); } }
}
export async function ensureProtocolParent(path) {
  try {
    if (typeof path !== "string" || !isAbsolute(path)) refuse("CLI_PRIVATE_FILE");
    try { await mkdir(path, { mode: 0o700 }); } catch (error) { if (error.code !== "EEXIST") throw error; }
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink() || !owned(info) || (info.mode & 0o077) !== 0) refuse("CLI_PRIVATE_FILE");
  } catch (error) { throw error instanceof CommunityProtocolCLIError ? error : new CommunityProtocolCLIError("CLI_PRIVATE_FILE"); }
}
export function requireProtocolFileAbsent(path) {
  try { lstatSync(path); } catch (error) { if (error.code === "ENOENT") return; refuse("CLI_FILE_WRITE"); }
  refuse("CLI_FILE_WRITE");
}

/** Publish a complete private file atomically; hard-link publication never overwrites an existing target. */
export async function publishProtocolPrivateJSON(path, value) {
  let temporary, handle;
  try {
    if (typeof path !== "string" || !isAbsolute(path)) refuse("CLI_FILE_WRITE");
    const directory = dirname(path), info = await lstat(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || !owned(info) || (info.mode & 0o077) !== 0) refuse("CLI_FILE_WRITE");
    const body = JSON.stringify(value, null, 2) + "\n";
    if (Buffer.byteLength(body) > 65536) refuse("CLI_FILE_WRITE");
    temporary = join(directory, ".protocol-" + randomUUID() + ".tmp");
    handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    await handle.writeFile(body); await handle.sync(); await handle.close(); handle = undefined;
    await link(temporary, path); await unlink(temporary); temporary = undefined;
    handle = await open(directory, constants.O_RDONLY); await handle.sync(); await handle.close(); handle = undefined;
  } catch { throw new CommunityProtocolCLIError("CLI_FILE_WRITE"); }
  finally {
    await handle?.close().catch(() => {});
    if (temporary) await unlink(temporary).catch(() => {});
  }
}
