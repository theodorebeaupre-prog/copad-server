// Integration tests for the Co/Pad helper's WebSocket protocol, message
// validation, and auth. Runs the real server.js on a test port (no keystrokes
// are injected — every case here is rejected or answered before osascript).
//
//   cd mac-helper && node --test
//
const { test, before, after } = require("node:test");
const assert = require("node:assert");
const { spawn } = require("child_process");
const net = require("net");
const path = require("path");
const WebSocket = require("ws");

const SERVER = path.join(__dirname, "server.js");

function waitForPort(port, tries = 50) {
  return new Promise((resolve, reject) => {
    const attempt = (n) => {
      const s = net.connect(port, "127.0.0.1");
      s.on("connect", () => { s.destroy(); resolve(); });
      s.on("error", () => {
        s.destroy();
        if (n <= 0) reject(new Error("server never listened"));
        else setTimeout(() => attempt(n - 1), 100);
      });
    };
    attempt(tries);
  });
}

function startServer(port, env = {}) {
  const proc = spawn("node", [SERVER], {
    env: { ...process.env, COPAD_PORT: String(port), COPAD_HAPTICS: "0", ...env },
    stdio: "ignore",
  });
  return proc;
}

function open(ws) {
  return new Promise((resolve, reject) => {
    ws.once("open", resolve);
    ws.once("error", reject);
  });
}

// Send one message, resolve with the next reply.
function rpc(ws, msg) {
  return new Promise((resolve) => {
    ws.once("message", (d) => resolve(JSON.parse(d.toString())));
    ws.send(JSON.stringify(msg));
  });
}

// ---- Auto-token server (default: COPAD_TOKEN unset) ------------------------
// Security regression tests: the server must NEVER run unauthenticated. With
// no COPAD_TOKEN it generates a random pairing code, so an empty token must
// always fail the handshake.

const PORT = 8799;
let server;

before(async () => {
  server = startServer(PORT); // no COPAD_TOKEN — must auto-generate one
  await waitForPort(PORT);
});
after(() => { if (server) server.kill(); });

test("default mode: empty token is rejected (no unauthenticated mode)", async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  await open(ws);
  const closed = new Promise((res) => ws.once("close", res));
  const r = await rpc(ws, { action: "hello", token: "" });
  assert.strictEqual(r.ok, false, "empty token must never authenticate");
  assert.strictEqual(r.error, "bad token");
  await closed;
});

test("default mode: actions ignored without any hello", async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
  await open(ws);
  let replied = false;
  ws.on("message", () => { replied = true; });
  ws.send(JSON.stringify({ action: "scan" }));
  await new Promise((r) => setTimeout(r, 400));
  assert.strictEqual(replied, false, "unauthed action must be ignored");
  ws.close();
});

test("default mode: browser Origin header is rejected at upgrade", async () => {
  // A malicious web page always sends Origin; native clients never do.
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}`, { headers: { Origin: "https://evil.example" } });
  const failed = new Promise((res) => ws.once("error", res));
  await failed;
});

async function authed() {
  // The auto-generated token is not exposed over the wire, so authenticate
  // against the explicit-token server below for protocol tests.
  const ws = new WebSocket(`ws://127.0.0.1:${TPORT}`);
  await open(ws);
  const r = await rpc(ws, { action: "hello", token: "s3cret" });
  assert.strictEqual(r.ok, true, "hello should authenticate with the token");
  return ws;
}

test("protocol smoke: scan replies with a targets list (token server)", async () => {
  const ws = await authed();
  const r = await rpc(ws, { action: "scan" });
  assert.strictEqual(r.type, "targets");
  assert.ok(Array.isArray(r.targets), "targets must be an array");
  ws.close();
});

const REJECTED = [
  ["unknown action", { action: "bogus" }],
  ["key missing", { action: "key" }],
  ["key too long", { action: "key", key: "a".repeat(50) }],
  ["text oversized", { action: "text", text: "x".repeat(5000) }],
  ["chrome cmd wrong type", { action: "chrome", cmd: 123 }],
  ["chrome url oversized", { action: "chrome", cmd: "open", url: "u".repeat(3000) }],
  ["bad target: empty app", { action: "raise", target: { app: "" } }],
  ["bad target: non-object", { action: "raise", target: "Terminal" }],
  ["bad windowId: not integer", { action: "key", key: "a", target: { app: "Terminal", windowId: 1.5 } }],
  ["mods not array", { action: "key", key: "a", mods: "command" }],
  ["mods too many", { action: "key", key: "a", mods: ["a", "b", "c", "d", "e"] }],
  ["app too long", { action: "app", app: "a".repeat(200) }],
];

for (const [name, msg] of REJECTED) {
  test(`rejects malformed message: ${name}`, async () => {
    const ws = await authed();
    const r = await rpc(ws, msg);
    assert.strictEqual(r.ok, false, `${name} should be rejected`);
    assert.strictEqual(r.error, "invalid message");
    ws.close();
  });
}

test("server survives a burst of malformed messages (no crash)", async () => {
  const ws = await authed();
  for (const [, msg] of REJECTED) await rpc(ws, msg);
  // still responsive:
  const r = await rpc(ws, { action: "scan" });
  assert.strictEqual(r.type, "targets");
  ws.close();
});

// ---- Token-protected server ------------------------------------------------

const TPORT = 8798;
let tserver;

before(async () => {
  tserver = startServer(TPORT, { COPAD_TOKEN: "s3cret" });
  await waitForPort(TPORT);
});
after(() => { if (tserver) tserver.kill(); });

test("token: correct token authenticates", async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${TPORT}`);
  await open(ws);
  const r = await rpc(ws, { action: "hello", token: "s3cret" });
  assert.strictEqual(r.ok, true);
  ws.close();
});

test("token: wrong token is rejected and connection closed", async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${TPORT}`);
  await open(ws);
  const closed = new Promise((res) => ws.once("close", res));
  const r = await rpc(ws, { action: "hello", token: "wrong" });
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.error, "bad token"); // the iPad app matches this string
  await closed; // server must close the socket on bad token
});

test("token: actions ignored before a valid hello", async () => {
  const ws = new WebSocket(`ws://127.0.0.1:${TPORT}`);
  await open(ws);
  // Send scan without authenticating — server must not reply with targets.
  let replied = false;
  ws.on("message", () => { replied = true; });
  ws.send(JSON.stringify({ action: "scan" }));
  await new Promise((r) => setTimeout(r, 400));
  assert.strictEqual(replied, false, "unauthed action must be ignored");
  ws.close();
});
