# Co/Pad Mac helper

Bridges the Co/Pad iPad app to your Mac. It listens on a local WebSocket and
replays incoming key events as real keystrokes into whatever app is **frontmost**
— normally your terminal running Claude Code.

## Setup

```bash
cd mac-helper
npm install
node server.js
```

On launch it prints the address to enter in the app, e.g. `ws://192.168.1.10:8787`.

## Grant Accessibility permission (required)

macOS blocks synthetic keystrokes until you allow them:

**System Settings → Privacy & Security → Accessibility** → enable the app that
runs the helper (Terminal, iTerm, or Node). If keys in the app do nothing, this
is almost always why. You may need to quit and relaunch the terminal after
toggling it on.

## Grant Automation permission (for per-window targeting)

To drive **several Claude Code sessions** and target a specific terminal window,
the helper reads your open windows and raises the one you pick. The first time it
does this macOS shows an **Automation** prompt ("… wants to control Terminal") —
click **OK**. It's a separate permission from Accessibility.

Without it, the pad still works: it falls back to **app-level** targets (raise
Terminal / iTerm2 / Claude / Warp / VS Code as a whole) instead of individual
windows.

## Use it

1. Put the iPad and Mac on the same Wi-Fi network.
2. Run the helper (above). It advertises itself over Bonjour as **"Co/Pad Helper"**.
3. In the app, tap the status pill (top-right) → tap **Co/Pad Helper** under
   "Discovered on this network". (Or enter the IP + port `8787` manually.)
4. Put your terminal/Claude Code window in front. Tap keys — they type into it.

The app auto-connects on later launches and reconnects automatically if the
connection drops.

## Trackpad haptics (on by default)

Every key you tap also fires a tick on the Mac's **Force Touch trackpad** (via
`NSHapticFeedbackManager`), so you feel the press on the Mac too — you only feel
it while a finger rests on the trackpad, and only on Macs that have one
(MacBooks / Magic Trackpad). A single long-lived helper process keeps it instant.

Disable with `COPAD_HAPTICS=0 node server.js`.

## Optional: voice out (Claude reads replies aloud — Kokoro)

The pad's **long-press MIC** asks the helper to read the active instance's latest
reply aloud with [Kokoro-82M](https://github.com/hexgrad/kokoro). This is
optional — everything else works without it. To enable:

```bash
python3 -m pip install kokoro soundfile numpy
brew install espeak-ng      # phonemizer backend Kokoro needs
```

The helper calls `kokoro_speak.py` (same folder). Configure via env:

```bash
KOKORO_LANG=a KOKORO_VOICE=af_heart node server.js   # a=US English, f=French, …
COPAD_PYTHON=/path/to/python3 node server.js          # if python3 isn't on PATH
```

If Kokoro isn't installed the helper logs a hint and keeps running — voice-out
is simply skipped. **Note:** Claude Code is a full-screen TUI, so the reply text
is *scraped* from the terminal and is approximate (works best on Terminal.app /
iTerm2 windows). Dictation (voice **in**) is handled on the iPad and needs none
of this.

## Optional: require a token

```bash
COPAD_TOKEN=some-secret node server.js
```

Then set the same token in the app's settings. Without a token anything on your
LAN can send keystrokes, so use one on shared networks.

## Protocol

Newline-free JSON messages over WebSocket:

| Message | Effect |
|---|---|
| `{"action":"hello","token":"…"}` | Auth handshake |
| `{"action":"scan"}` | Replies `{"type":"targets","targets":[…]}` — the Claude Code instances found |
| `{"action":"text","text":"/clear","submit":true,"target":{…}}` | Raises `target`, types text, optional Return |
| `{"action":"key","key":"enter\|up\|…\|t\|l\|[","mods":["command","shift"],"target":{…}}` | Raises `target`, presses a key or shortcut (`mods` optional) |
| `{"action":"raise","target":{…}}` | Brings a target to the front (no typing) |
| `{"action":"speak","text":"…"}` | Speaks text aloud via Kokoro (if installed) |
| `{"action":"read","target":{…}}` | Scrapes the target's reply and speaks it; replies `{"type":"spoke","text":…}` |
| `{"action":"app","app":"WARP"}` | Legacy: brings a named Mac app to the front |

A `target` is `{"app":"Terminal","windowId":1234,"label":"…"}` (window-level, from
`scan`) or `{"app":"Warp","label":"…"}` (app-level). Omit `target` to type into
whatever is frontmost.
