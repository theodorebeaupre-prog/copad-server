<div align="center">

# Co/Pad Server

**The Mac side of [Co/Pad](#about) — turn an iPad into a physical control surface for Claude Code.**

Tap a key on the iPad and it types straight into Claude Code (or any app) on your Mac.
Like a Stream Deck, built for vibecoding.

`iPad ──ws──▶ Co/Pad Server (this repo) ──▶ Terminal · Claude Code · Chrome · anything`

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-black)
![node](https://img.shields.io/badge/node-18%2B-5a5)
![license](https://img.shields.io/badge/license-MIT-orange)

</div>

---

## About

**Co/Pad** is a personal macro pad for Claude Code that runs on an iPad. The iPad
app is a grid of programmable keys, a scroll dial, a voice button and a targets
row. This repository is the **Mac server** it talks to: a local WebSocket service
that replays the iPad's key events as real macOS keystrokes, routes them to the
right window, and adds trackpad haptics and voice output.

You run the server on your Mac, the app on your iPad, both on the same Wi‑Fi.
Tap keys on the tablet → they land in whatever Claude Code session (or app) you
picked.

> This repo contains the **server** (a native menu‑bar app + the Node helper it
> wraps). The iPad app is a separate SwiftUI project.

---

## Why

Claude Code lives in a terminal. When you're deep in a session you're constantly
typing the same things — `/clear`, `/compact`, `ultrathink`, arrow keys to accept
prompts, Enter to submit. Co/Pad puts those on dedicated hardware keys under your
fingers, lets you **jump between multiple sessions**, **dictate by voice**, and
**drive other Mac apps** (Chrome, Slack, VS Code) — all without touching the Mac
keyboard.

---

## Features

- 🎹 **Real keystrokes** — types text and presses keys (arrows, Enter, Esc, Tab…)
  into the frontmost app via macOS System Events.
- 🎯 **Multi‑instance targeting** — discovers every Claude Code host (Terminal,
  iTerm2, Warp, the Claude app, VS Code, Cursor…) *and* every running app.
  Terminal & iTerm2 are targeted **window by window**, so you can drive several
  Claude Code sessions and switch between them from the pad.
- ⌘ **Keyboard shortcuts** — send real modifier combos (⌘T, ⌘W, ⌘L, ⌘R…) to
  control browsers and any Mac app.
- 🗣️ **Voice** — the iPad dictates on‑device (Apple Speech); the server can read
  Claude's replies back aloud with [Kokoro‑82M](https://github.com/hexgrad/kokoro) TTS.
- 📳 **Trackpad haptics** — every key also ticks the Mac's Force Touch trackpad
  (`NSHapticFeedbackManager`).
- 🖥️ **Menu‑bar app** — no terminal required; runs the helper, shows status and
  the address, and opens the permission panes you need.
- 🔒 **Local‑only** — plain `ws://` on your LAN, optional shared‑secret token.
  Zero‑config discovery over Bonjour.

---

## What's in this repo

| Path | What it is |
|---|---|
| `mac-app/` | Native **menu‑bar app** (AppKit, single Swift file) that runs the helper — no terminal. |
| `mac-helper/` | The **Node WebSocket server**: keystroke injection, target discovery, haptics, TTS bridge. |

The menu‑bar app is a thin, robust wrapper that launches `mac-helper/server.js`
as a child process. All the actual work lives in the helper, so you can run
either one.

---

## Requirements

- **macOS 13+** with a Force Touch trackpad (MacBook / Magic Trackpad) for haptics.
- **Node 18+** (Homebrew, `/usr/local`, or nvm — the app finds it automatically).
- An iPad on the **same Wi‑Fi** running the Co/Pad app.
- *(optional)* Python 3 + [Kokoro](https://github.com/hexgrad/kokoro) for voice‑out.

---

## Install & run

### Option A — the menu‑bar app (recommended)

```bash
cd mac-app
./build.sh
open "build/CoPad Server.app"
```

`build.sh` compiles the app, bundles the helper (`server.js`, `node_modules`,
`kokoro_speak.py`) into it, and ad‑hoc signs it. A `/` glyph appears in your menu
bar — that's the server. The menu shows the status, the `ws://…` address, and
buttons to open the permission panes.

### Option B — the raw helper

```bash
cd mac-helper
npm install
node server.js
```

It prints the address to use, e.g. `ws://192.168.1.10:8787`.

---

## Permissions (important)

macOS gates two things. Grant them to **whatever runs the server** — "Co/Pad
Server" for the app, or your terminal for the raw helper.

| Permission | Why | Where |
|---|---|---|
| **Accessibility** | Send synthetic keystrokes. Without it, keys do nothing. | System Settings → Privacy & Security → **Accessibility** |
| **Automation** | Read open windows for per‑window targeting, and read replies for Kokoro. | Approved on first use, or the app's *Open Automation Settings…* |

The menu‑bar app has shortcuts to both panes. Without Automation you still get
**app‑level** targets (raise Terminal / Chrome / … as a whole).

---

## Protocol

Newline‑free JSON over a WebSocket. Send `hello` first; the iPad app does the rest.

| Message | Effect |
|---|---|
| `{"action":"hello","token":"…"}` | Auth handshake |
| `{"action":"scan"}` | Replies `{"type":"targets","targets":[…]}` — routable instances |
| `{"action":"text","text":"/clear","submit":true,"target":{…}}` | Raise target, type text, optional Return |
| `{"action":"key","key":"enter","mods":["command"],"target":{…}}` | Raise target, press a key or shortcut |
| `{"action":"raise","target":{…}}` | Bring a target to the front |
| `{"action":"speak","text":"…"}` | Speak text via Kokoro |
| `{"action":"read","target":{…}}` | Scrape the target's reply and speak it |

A `target` is `{"app":"Terminal","windowId":1234}` (window‑level) or
`{"app":"Chrome"}` (app‑level). Omit it to type into whatever is frontmost.

---

## Voice out (Kokoro)

Optional — the pad's long‑press MIC has Claude's latest reply read aloud.

```bash
python3 -m pip install kokoro soundfile numpy
brew install espeak-ng
```

Configure via env: `KOKORO_LANG` (`a` US English, `f` French, …), `KOKORO_VOICE`
(default `af_heart`). The helper degrades gracefully if Kokoro isn't installed.

> Claude Code is a full‑screen TUI, so the reply text is *scraped* from the
> terminal and is approximate — best on Terminal.app / iTerm2 windows.

---

## Configuration (env vars)

| Var | Default | Purpose |
|---|---|---|
| `COPAD_PORT` | `8787` | WebSocket port |
| `COPAD_TOKEN` | *(none)* | Shared secret; set the same in the app to lock down shared networks |
| `COPAD_HAPTICS` | on | `0` disables trackpad haptics |
| `COPAD_PYTHON` | `python3` | Python used for Kokoro |
| `KOKORO_LANG` / `KOKORO_VOICE` | `a` / `af_heart` | Kokoro voice |

---

## How it works

1. The iPad connects over a LAN WebSocket (discovered via Bonjour, `_copad._tcp`).
2. Each key event carries the active **target**. The server raises that app — and,
   for Terminal/iTerm2, that specific window — then injects the keystroke with
   AppleScript / System Events.
3. Trackpad haptics are fired from a single long‑lived helper process that keeps
   AppKit loaded, so each tick is instant.
4. Voice‑out shells out to a small Python bridge that runs Kokoro and plays the
   audio through the Mac.

---

## Security

`ws://` is plaintext and fine for a home LAN. On shared/untrusted networks set
`COPAD_TOKEN` on the server and the same token in the app — otherwise anything on
the LAN could send keystrokes to your Mac. The server only ever runs locally and
makes no outbound connections.

---

## Troubleshooting

- **Keys do nothing** → Accessibility not granted (see above); quit & relaunch the
  server after toggling it.
- **Only app‑level targets, no windows** → grant Automation; approve the prompt on
  first window scan.
- **iPad can't find the server** → same Wi‑Fi? Allow the app's local‑network
  prompt. You can always enter the IP + port `8787` manually.
- **No sound from Kokoro** → not installed, or wrong `COPAD_PYTHON`; the helper
  logs a hint and keeps running.

---

## Roadmap

- Signed / notarized app release.
- Configurable haptic patterns.
- More robust reply capture for voice‑out.

---

## Contributing

Issues and PRs welcome. The helper is plain Node (no build step); the app is a
single Swift file built by `mac-app/build.sh`. Keep it dependency‑light.

## License

[MIT](LICENSE).
