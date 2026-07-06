# Co/Pad Server

Turn an iPad into a physical control surface for your Mac — Claude Code, Codex,
Chrome, Mail, Apple Music, Lightroom, or any app. Tap a key on the iPad and it
acts on your Mac — like a Stream Deck, built for people who live in the keyboard.

```
iPad ──ws──▶ Co/Pad Server ──▶ Terminal · Codex · Chrome · Music · anything
```

This is the **macOS server**: a menu‑bar app (`mac-app/`) that runs a local
WebSocket helper (`mac-helper/`) and turns the iPad's events into real Mac input:
multi‑instance targeting, keyboard shortcuts, **Chrome** (open URL / reload) and
**Apple Music** actions, trackpad haptics, and Kokoro voice‑out. Every incoming
message is validated and injection‑safe.

> **📱 The Co/Pad iPad app is coming soon to the App Store.** This server is its
> free companion — install it now and you'll be ready the day the app ships.

## Download

Grab the app from **[Releases](https://github.com/theodorebeaupre-prog/copad-server/releases/latest)**.

It's signed with a development identity (not notarized), so on first launch
macOS blocks it — **right‑click → Open**, or clear quarantine:

```bash
xattr -dr com.apple.quarantine "CoPad Server.app"
```

Requires **Node 18+** installed (Homebrew, `/usr/local`, or nvm — found
automatically).

## Or build from source

```bash
cd mac-app && ./build.sh
open "build/CoPad Server.app"
```

## Permissions

Grant these to **Co/Pad Server** (System Settings → Privacy & Security):

- **Accessibility** — to send keystrokes. Without it, keys do nothing.
- **Automation** — for per‑window targeting and Kokoro reply read‑back (prompted on first use).

## Run

The `/` glyph in your menu bar is the server; it shows the `ws://…:8787` address
and a **pairing code**. Put your iPad on the same Wi‑Fi, tap the helper in the
app, enter the pairing code (Settings → Pairing code), and go. The code is
required — it keeps anyone else on the network from sending keystrokes to your
Mac.

Env toggles: `COPAD_PORT`, `COPAD_TOKEN`, `COPAD_HAPTICS=0`, `COPAD_PYTHON`,
`KOKORO_LANG`/`KOKORO_VOICE`. See [`mac-helper/README.md`](mac-helper/README.md)
for the protocol and Kokoro setup.

> **macOS 15/26:** the Accessibility grant only persists if the app is signed
> with a **trusted Apple identity**. `build.sh` picks your Apple Development /
> Developer ID cert automatically — see [`mac-app/README.md`](mac-app/README.md#keep-accessibility-across-rebuilds-stable-signing).

## Tests

```bash
cd mac-helper && npm install && npm test   # WebSocket parser, validation, token auth
```

## License

[MIT](LICENSE).
