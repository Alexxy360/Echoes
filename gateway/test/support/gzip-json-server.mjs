import { createServer } from "node:http";
import { gzipSync } from "node:zlib";

/** Loopback only: real fetch decoding with a compressed entity length. Never forwards API headers. */
export async function gzipJSONServer(t, value) {
  let calls = 0;
  const server = createServer((_request, response) => {
    calls++;
    const body = gzipSync(Buffer.from(JSON.stringify(value())));
    response.writeHead(200, { "Content-Type": "application/json", "Content-Encoding": "gzip", "Content-Length": String(body.byteLength) });
    response.end(body);
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  t.after(async () => {
    const closed = new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    server.closeAllConnections();
    await closed;
  });
  const url = "http://127.0.0.1:" + server.address().port;
  return { get calls() { return calls; }, fetch(signal) { return fetch(url, { signal, redirect: "error" }); } };
}
