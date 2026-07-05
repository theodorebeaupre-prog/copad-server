# Co/Pad Server (macOS menu-bar app)

A native menu-bar app that runs the Co/Pad helper — no terminal, no `node`
command to remember. It launches `server.js` (the proven helper) as a child
process and shows status in the menu bar.

```
┌ menu bar ─────────────┐
│ Co/Pad Server         │
│ ● Running — 1 connected│
│ ws://192.168.x.x:8787 │  ← click to copy
│ ───────────────────── │
│ Restart Helper        │
│ Open Accessibility…   │
│ Open Automation…      │
│ Quit                  │
└───────────────────────┘
```

## Build

```bash
cd mac-app
./build.sh
open "build/Co/Pad Server.app"   # actually build/CoPad Server.app
```

`build.sh` compiles `main.swift` (AppKit), bundles the app, and copies the
helper (`server.js`, `package.json`, `node_modules`, `kokoro_speak.py`) into
`Contents/Resources`, then ad-hoc signs it. Requires Node 18+ installed
(Homebrew, `/usr/local`, or nvm — the app finds it automatically).

## Permissions

The app is the responsible process for TCC, so you grant permissions to
**"Co/Pad Server"** (not your terminal):

- **Accessibility** — required to send keystrokes. Menu → *Open Accessibility Settings…*
- **Automation** — for window-level targeting (Terminal / iTerm) and reading
  replies for Kokoro. Approved on first use, or Menu → *Open Automation Settings…*

## Notes

- Menu-bar only (`LSUIElement`) — no Dock icon.
- Quitting the app stops the helper.
- It's the same `server.js`, so all env toggles still apply — launch from a
  terminal once with `COPAD_TOKEN=… COPAD_HAPTICS=0 …` if you need them, or set
  them in the plist later.
