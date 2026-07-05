#!/usr/bin/env node
/*
 * Co/Pad Mac helper
 * -----------------
 * Receives key events from the Co/Pad iPad app over a local WebSocket and
 * replays them as real keystrokes on your Mac.
 *
 * By default keys go to whatever app is frontmost. When the app sends a
 * `target` (a specific Claude Code instance), the helper raises that app —
 * and, for Terminal.app / iTerm2, that specific window — before typing, so
 * you can drive several Claude Code sessions from one pad.
 *
 * Requires: Node 18+, `npm install`, and Accessibility permission granted to
 * whatever runs this (Terminal / iTerm / node). See README.md.
 */

const { WebSocketServer } = require("ws");
const { execFile, spawn } = require("child_process");
const os = require("os");
const path = require("path");

const PORT = parseInt(process.env.COPAD_PORT || "8787", 10);
const TOKEN = process.env.COPAD_TOKEN || ""; // optional shared secret
const PYTHON = process.env.COPAD_PYTHON || "python3";
const KOKORO_SCRIPT = path.join(__dirname, "kokoro_speak.py");
const MAC_HAPTICS = process.env.COPAD_HAPTICS !== "0"; // Force Touch trackpad feedback

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// macOS virtual key codes for special keys.
const KEY_CODES = {
  enter: 36, return: 36,
  left: 123, right: 124, down: 125, up: 126,
  delete: 51, forwarddelete: 117,
  escape: 53, tab: 48, space: 49,
  home: 115, end: 119, pageup: 116, pagedown: 121,
};

// Display name in the app  ->  actual macOS application name (legacy `app` action).
const APP_MAP = {
  WARP: "Warp", SLACK: "Slack", ARC: "Arc", FIGMA: "Figma",
};

// Apps that can host a Claude Code session. Terminal & iTerm2 are enumerated
// window-by-window; the rest are targeted at the app level.
const KNOWN_APPS = [
  "Terminal", "iTerm2", "Warp", "Ghostty", "Alacritty", "kitty", "WezTerm",
  "Claude", "Code", "Cursor", "Windsurf",
];
const WINDOW_SCRIPTABLE = new Set(["Terminal", "iTerm2"]);

// `timeout` guards against a blocked osascript (e.g. an un-granted Automation
// prompt) hanging the whole connection — the call is killed and rejected so
// discovery degrades to an empty list instead of freezing the pad.
function osa(script, timeout = 4000) {
  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", script], { timeout, killSignal: "SIGKILL" }, (err, stdout, stderr) => {
      if (err) reject(new Error(stderr || err.message));
      else resolve(stdout);
    });
  });
}

function typeText(text) {
  const escaped = String(text).replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return osa(`tell application "System Events" to keystroke "${escaped}"`);
}

function pressKey(code) {
  return osa(`tell application "System Events" to key code ${code}`);
}

// Build an AppleScript ` using {command down, …}` clause from modifier names.
const MOD_MAP = {
  command: "command down", cmd: "command down", "⌘": "command down",
  option: "option down", opt: "option down", alt: "option down", "⌥": "option down",
  control: "control down", ctrl: "control down", "⌃": "control down",
  shift: "shift down", "⇧": "shift down",
};
function modsClause(mods) {
  const parts = (mods || []).map((m) => MOD_MAP[String(m).toLowerCase()]).filter(Boolean);
  return parts.length ? ` using {${parts.join(", ")}}` : "";
}

// Send a key or a shortcut. `name` is a special key (enter/tab/up…) or a single
// character ("t", "l", "["); `mods` optionally adds command/option/control/shift.
function sendKey(name, mods) {
  const clause = modsClause(mods);
  const code = KEY_CODES[String(name).toLowerCase()];
  if (code != null) {
    return osa(`tell application "System Events" to key code ${code}${clause}`);
  }
  const ch = String(name);
  if (ch.length !== 1) return Promise.resolve();
  const esc = ch.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return osa(`tell application "System Events" to keystroke "${esc}"${clause}`);
}

function activateApp(name) {
  const safe = String(name).replace(/"/g, '\\"');
  return osa(`tell application "${safe}" to activate`);
}

// ---- Target discovery & routing ------------------------------------------

// Names of foreground (non-background) apps currently running.
async function runningApps() {
  try {
    const out = await osa(
      `tell application "System Events" to get name of (every process whose background only is false)`
    );
    return out.split(",").map((s) => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

// { id, title } for every window of a scriptable terminal app.
async function listWindows(app) {
  const script =
    `tell application "${app}"\n` +
    `  set out to ""\n` +
    `  repeat with w in windows\n` +
    `    set out to out & (id of w) & tab & (name of w) & linefeed\n` +
    `  end repeat\n` +
    `  return out\n` +
    `end tell`;
  let raw = "";
  try { raw = await osa(script); } catch { return []; }
  return raw
    .split("\n")
    .map((l) => l.replace(/\r$/, ""))
    .filter((l) => l.trim().length)
    .map((l) => {
      const t = l.indexOf("\t");
      const id = parseInt(t >= 0 ? l.slice(0, t) : l, 10);
      const title = (t >= 0 ? l.slice(t + 1) : "").trim();
      return Number.isFinite(id) ? { id, title } : null;
    })
    .filter(Boolean);
}

// Apps never worth showing as a keystroke target (system agents / self).
const EXCLUDE_APPS = new Set(["Dock", "SystemUIServer", "Control Center", "Notification Center", "Spotlight", "loginwindow", "WindowManager"]);

// Build the list of routable targets the iPad shows as chips. Claude Code hosts
// come first (window-level where possible), then every other running app so you
// can drive Chrome, Slack, Figma… — anything on screen.
async function scanTargets() {
  const running = await runningApps();
  const targets = [];
  const seen = new Set();

  for (const app of KNOWN_APPS) {
    if (!running.includes(app)) continue;
    seen.add(app);
    if (WINDOW_SCRIPTABLE.has(app)) {
      const wins = await listWindows(app);
      if (wins.length) {
        for (const w of wins) {
          targets.push({
            id: `win:${app}:${w.id}`,
            app,
            windowId: w.id,
            label: w.title ? `${app} · ${w.title}` : `${app} · window ${w.id}`,
          });
        }
        continue;
      }
    }
    targets.push({ id: `app:${app}`, app, label: app });
  }

  for (const app of running) {
    if (seen.has(app) || EXCLUDE_APPS.has(app)) continue;
    seen.add(app);
    targets.push({ id: `app:${app}`, app, label: app });
  }

  return targets;
}

// Bring a specific target to the front before typing. `st.lastRaised` avoids
// re-activating the same target on every keystroke (keeps arrows / the dial snappy).
async function raiseTarget(target, st) {
  if (!target || !target.app) return;
  const app = String(target.app);
  const wid = target.windowId;
  const key = wid != null ? `${app}#${wid}` : app;
  if (st && st.lastRaised === key) return;
  try {
    if (wid != null && app === "Terminal") {
      await osa(
        `tell application "Terminal"\n` +
        `  activate\n` +
        `  try\n    set index of (first window whose id is ${wid | 0}) to 1\n  end try\n` +
        `end tell`
      );
    } else if (wid != null && (app === "iTerm2" || app === "iTerm")) {
      await osa(
        `tell application "iTerm2"\n` +
        `  activate\n` +
        `  try\n    select (first window whose id is ${wid | 0})\n  end try\n` +
        `end tell`
      );
    } else {
      await activateApp(app);
    }
    await sleep(60); // let activation settle so keystrokes land in the right place
    if (st) st.lastRaised = key;
  } catch (e) {
    console.error("raise:", e.message);
  }
}

// ---- Voice out (Kokoro TTS) ----------------------------------------------

// Speak `text` through the Mac via the Kokoro bridge. Degrades quietly if
// Python / Kokoro isn't installed — the pad keeps working without voice-out.
function speak(text) {
  return new Promise((resolve) => {
    const t = String(text || "").trim();
    if (!t) return resolve();
    let err = "";
    let p;
    try {
      p = spawn(PYTHON, [KOKORO_SCRIPT], { stdio: ["pipe", "ignore", "pipe"] });
    } catch (e) {
      console.error("speak: cannot launch python —", e.message);
      return resolve();
    }
    p.stderr.on("data", (d) => (err += d.toString()));
    p.on("error", (e) => { console.error("speak: python not found —", e.message); resolve(); });
    p.on("close", (code) => {
      if (code === 3) console.error("speak: Kokoro not installed — see mac-helper/README.md (voice out)");
      else if (code) console.error("speak: exited", code, err.trim());
      resolve();
    });
    p.stdin.write(t);
    p.stdin.end();
  });
}

// Best-effort: pull the visible text of a target terminal so Kokoro can read
// back Claude's latest reply. Claude Code is a redrawing TUI, so this strips
// box-drawing chrome and returns the tail — approximate, not exact.
async function readReply(target) {
  if (!target) return "";
  const app = String(target.app || "");
  const wid = target.windowId;
  try {
    if (app === "Terminal" && wid != null) {
      const raw = await osa(
        `tell application "Terminal" to get contents of selected tab of (first window whose id is ${wid | 0})`
      );
      return lastReply(raw);
    }
    if ((app === "iTerm2" || app === "iTerm") && wid != null) {
      const raw = await osa(
        `tell application "iTerm2" to tell (first window whose id is ${wid | 0}) to tell current session to get text`
      );
      return lastReply(raw);
    }
  } catch (e) {
    console.error("read:", e.message);
  }
  return "";
}

function lastReply(raw) {
  const lines = String(raw)
    .split("\n")
    .map((l) => l.replace(/[│╭╮╰╯─━┃╌┄┈▏▕┌┐└┘├┤┬┴┼>·•]/g, "").trim())
    .filter((l) => l.length);
  return lines.slice(-12).join(". ").slice(0, 600);
}

// ---- Mac trackpad haptics -------------------------------------------------

// A single long-lived JXA process keeps AppKit loaded; each byte we write to
// its stdin fires one tick on the Mac's Force Touch trackpad (felt when a
// finger rests on it). Spawning per key would cost ~280ms — this is instant.
let hapticProc = null;
let hapticDead = false;
function macHaptic() {
  if (!MAC_HAPTICS || hapticDead) return;
  try {
    if (!hapticProc) {
      // EOF detection is `+d.length===0`, and that exact form matters. In JXA
      // `availableData.length` at EOF is the *string* "0", so `d.length===0`
      // (string≠number) and `!d.length` (`!"0"` is false) both fail — which is
      // why a dead-parent reader once span the CPU forever and buzzed the
      // trackpad nonstop. `+d.length` coerces the string to a number so the loop
      // ends the instant the write end closes. While node is alive
      // `availableData` blocks (no CPU); it fires one tick per byte written.
      const jxa =
        "ObjC.import('AppKit');ObjC.import('Foundation');" +
        "var p=$.NSHapticFeedbackManager.defaultPerformer;" +
        "var h=$.NSFileHandle.fileHandleWithStandardInput;" +
        "while(true){var d=h.availableData;if(!d||+d.length===0)break;" +
        "p.performFeedbackPatternPerformanceTime(0,1);}";
      hapticProc = spawn("osascript", ["-l", "JavaScript", "-e", jxa], {
        stdio: ["pipe", "ignore", "ignore"],
      });
      hapticProc.on("error", () => { hapticDead = true; hapticProc = null; });
      hapticProc.on("close", () => { hapticProc = null; });
    }
    hapticProc.stdin.write("\n");
  } catch {
    /* trackpad haptics unavailable — silently skip */
  }
}
function stopHaptics() { if (hapticProc) { hapticProc.stdin.end(); hapticProc = null; } }

function localAddresses() {
  const nets = os.networkInterfaces();
  const out = [];
  for (const name of Object.keys(nets)) {
    for (const net of nets[name] || []) {
      if (net.family === "IPv4" && !net.internal) out.push(net.address);
    }
  }
  return out;
}

// Advertise over Bonjour so the iPad app discovers us with no IP typing.
// `dns-sd` ships with macOS; we keep the process alive for the registration.
let bonjour;
function advertise() {
  try {
    bonjour = spawn("dns-sd", ["-R", "Co/Pad Helper", "_copad._tcp", "local", String(PORT)]);
    bonjour.on("error", () => console.log("(bonjour unavailable — use the IP manually)"));
  } catch {
    /* dns-sd missing; manual IP still works */
  }
}
function stopAdvertise() { if (bonjour) { bonjour.kill(); bonjour = null; } }

const wss = new WebSocketServer({ port: PORT });

wss.on("listening", () => {
  advertise();
  console.log("Co/Pad helper listening on:");
  for (const ip of localAddresses()) console.log(`   ws://${ip}:${PORT}   <-- or just tap "Co/Pad Helper" in the app`);
  if (TOKEN) console.log("   (token required)");
  console.log(`   trackpad haptics: ${MAC_HAPTICS ? "on (COPAD_HAPTICS=0 to disable)" : "off"}`);
  console.log("\nGrant Accessibility permission if keystrokes do nothing:");
  console.log("   System Settings > Privacy & Security > Accessibility\n");
});

process.on("SIGINT", () => { stopAdvertise(); stopHaptics(); process.exit(0); });
process.on("SIGTERM", () => { stopAdvertise(); stopHaptics(); process.exit(0); });

wss.on("connection", (ws, req) => {
  let authed = TOKEN === "";
  const connState = { lastRaised: null };
  console.log(`[+] client connected ${req.socket.remoteAddress}`);

  ws.on("message", async (raw) => {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }

    if (msg.action === "hello") {
      authed = TOKEN === "" || msg.token === TOKEN;
      ws.send(JSON.stringify({ ok: authed }));
      if (!authed) { console.log("[!] bad token, closing"); ws.close(); }
      return;
    }
    if (!authed) return;

    try {
      switch (msg.action) {
        case "text":
          macHaptic();
          await raiseTarget(msg.target, connState);
          if (msg.text) await typeText(msg.text);
          if (msg.submit) await pressKey(KEY_CODES.enter);
          console.log(`text  "${msg.text}"${msg.submit ? " + return" : ""}${msg.target ? " → " + (msg.target.label || msg.target.app) : ""}`);
          break;
        case "key": {
          macHaptic();
          await raiseTarget(msg.target, connState);
          await sendKey(msg.key, msg.mods);
          console.log(`key   ${(msg.mods && msg.mods.length ? msg.mods.join("+") + "+" : "")}${msg.key}`);
          break;
        }
        case "raise":
          await raiseTarget(msg.target, connState);
          console.log(`raise ${msg.target ? (msg.target.label || msg.target.app) : "-"}`);
          break;
        case "scan": {
          const targets = await scanTargets();
          ws.send(JSON.stringify({ type: "targets", targets }));
          console.log(`scan  ${targets.length} target(s)`);
          return; // response already sent
        }
        case "speak":
          console.log(`speak "${String(msg.text || "").slice(0, 40)}"`);
          await speak(msg.text);
          break;
        case "read": {
          const text = await readReply(msg.target);
          console.log(`read  ${text ? `"${text.slice(0, 40)}…"` : "(nothing)"}`);
          if (text) await speak(text);
          ws.send(JSON.stringify({ type: "spoke", text }));
          return; // response already sent
        }
        case "app": { // legacy app switcher
          const app = APP_MAP[msg.app] || msg.app;
          await activateApp(app);
          connState.lastRaised = null;
          console.log(`app   ${app}`);
          break;
        }
        default:
          break;
      }
      ws.send(JSON.stringify({ ok: true }));
    } catch (e) {
      console.error("!", e.message);
      ws.send(JSON.stringify({ ok: false, error: e.message }));
    }
  });

  ws.on("close", () => console.log("[-] client disconnected"));
  ws.on("error", (e) => console.error("ws error:", e.message));
});
