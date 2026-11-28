import test from "node:test";
import assert from "node:assert/strict";
import { avatarDownloadURL, avatarDownloadHosts } from "../src/avatar-protected-download.mjs";
const hosts = avatarDownloadHosts(["cvws.icloud-content.com"]);

test("Apple filename placeholder expands only the terminal path segment, preserving signed query bytes", () => {
  const url = 'https://cvws.icloud-content.com/B/opaque/${f}?s=SYNTHETIC%2Fabc&x=1';
  assert.equal(avatarDownloadURL(url, hosts), "https://cvws.icloud-content.com/B/opaque/avatar.jpg?s=SYNTHETIC%2Fabc&x=1");
});
test("filename placeholder never changes authority, query or a nonterminal path", () => {
  for (const url of [
    'https://${f}.icloud-content.com/file', 'https://cvws.icloud-content.com/file?s=${f}',
    'https://cvws.icloud-content.com/${f}/other?s=x', 'https://cvws.icloud-content.com/${f}/${f}?s=x',
    'https://cvws.icloud-content.com/a${f}?s=x', 'https://cvws.icloud-content.com/${f}#',
    'https://cvws.icloud-content.com/a/../${f}?s=x', 'https://cvws.icloud-content.com\\bad/${f}?s=x',
  ]) assert.throws(() => avatarDownloadURL(url, hosts));
});
