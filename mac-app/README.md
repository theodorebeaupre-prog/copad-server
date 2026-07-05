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

## Keep Accessibility across rebuilds (stable signing)

Ad-hoc signing changes the app's signature on every build, so macOS revokes the
**Accessibility** grant each time and keystroke macros stop working. `build.sh`
automatically signs with the best identity it finds, in this order:

**Developer ID Application → Apple Development → self-signed → ad-hoc.**

### Best: an Apple identity (required on macOS 15 / Sequoia+)
If you have an Apple Developer account, you already have an **Apple Development**
(or Developer ID) certificate — `build.sh` uses it with no setup. It chains to
Apple Root CA, so **TCC honors the grant and it persists across rebuilds**. Verify:

```bash
security find-identity -v -p codesigning   # look for "Apple Development" / "Developer ID"
```

> On **macOS 15/26**, TCC does **not** honor Accessibility for an untrusted
> self-signed certificate — a trusted Apple identity is required for the grant to
> stick. (Older macOS accepts the self-signed fallback below.)

### Fallback: a self-signed identity (older macOS, no Apple account)
```bash
cd /tmp
openssl req -newkey rsa:2048 -nodes -keyout copad-key.pem -x509 -days 3650 \
  -out copad-cert.pem -subj "/CN=CoPad Self-Signed" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out copad.p12 -inkey copad-key.pem -in copad-cert.pem -passout pass:copad
security import copad.p12 -k ~/Library/Keychains/login.keychain-db -P copad -T /usr/bin/codesign
```

After the first signed build, grant Accessibility once — it then persists.
If a stale grant lingers from earlier ad-hoc builds, **remove** the old
"Co/Pad Server" entry in Accessibility settings and **re-add** the app.

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
