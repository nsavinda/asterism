# Project: Asterism (Spicetify → Quickshell)

Notes for an AI coding agent working on this project on the user's own machine. The job is to
install, configure, test and debug a desktop lyrics visualizer. Work step by step, verify each
step, and fix problems yourself where you can. Ask the user only when you need them to do
something physical (play a song, look at the screen). User documentation is in `README.md`.

## Target system

- Arch Linux, Hyprland (Wayland)
- Quickshell (QML) 0.3+, Qt 6.8+ with `qt6-websockets`
- Spotify desktop client patched with Spicetify (optional: other players work over MPRIS)
- `cava` for audio levels (optional), Inter font (optional)

## What it is

Synced lyrics drawn as constellations while Spotify plays:

- Each word appears as a star (✦) when it is sung; the stars of a line are linked in order.
- The current word is large and white with a glow in the song's colour; earlier words shrink and dim.
- A faint ghost star shows where the next word will land.
- When the next line starts, the old constellation fades out and a new one fades in.
- Colours come from the album cover. A light runs around the screen edge.
- Sizes, particles and brightness follow the music (beat bounce, loudness dynamics, mood).
- Two modes: a click-through overlay above windows, and a fullscreen mode with a blurred cover
  backdrop, ambient light and a starfield. Fullscreen is the default; `Esc` exits it.
- In fullscreen, other monitors get a slow edge glow.

## Architecture

```
Spotify + Spicetify extension (spicetify/lyrics-bridge.js)
   │  lyrics, in order:
   │   1. Spicy Lyrics' local cache (if installed; CacheStorage "SpicyLyrics_LyricsStore_g1",
   │      read-only, no extra requests) → real word timing for "Syllable" songs
   │   2. Spotify color-lyrics API  3. LRCLIB (lrclib.net)
   │  line-synced sources: line timings → estimated word timings
   │  if Spicy's cache fills after another source was sent, upgrades within ~10 s
   │  cover colour: dominant vivid hue of the cover image (canvas), colorExtractor as fallback
   │  sends JSON over WebSocket ws://127.0.0.1:8975
   ▼
Quickshell config "lyrics" (quickshell/shell.qml + Constellation.qml)
   • QtWebSockets WebSocketServer on 127.0.0.1:8975
   • position clock: 16 ms Timer + FrameAnimation, both computed from wall time
   • PanelWindow on WlrLayer.Overlay; click-through (empty mask) unless fullscreen
   • fullscreen: on-demand keyboard focus + HyprlandFocusGrab (never Exclusive: that locks
     the keyboard on every monitor)
   • cava process → beat, bounce, energy, dyn (loudness vs ~17 s baseline), mood
   • cover image from MPRIS (Quickshell.Services.Mpris)
   • any other player (`anyPlayer`): `pollMpris()` runs every 500 ms, follows the playing MPRIS
     player, fetches LRCLIB lyrics itself (XMLHttpRequest), samples the cover colour with an
     invisible Canvas, and syncs the position from MPRIS. `owner` is "bridge" or "mpris";
     the bridge wins while Spotify plays with the extension connected.
   • state file ~/.local/state/lyrics-constellation ("0" = off) shared with bar buttons
   • IpcHandler target "lyrics": toggle, on, off, isOn, fullscreen, exitFullscreen,
     isFullscreen, position, mood, source
```

### Message protocol (extension → Quickshell)

```json
{ "type": "track", "id": "...", "title": "...", "artist": "...",
  "source": "spicy-syllable|spicy-line|spotify|lrclib|none",
  "colors": { "primary": "#rrggbb", "secondary": "#rrggbb", "dark": "#rrggbb", "from": "cover|extractor" },
  "lines": [ { "t": 12340, "end": 15800, "words": [ { "text": "hello", "t": 12340 } ] } ] }

{ "type": "state", "position": 12500, "playing": true }
```

Times are milliseconds. `colors` is `null` for greyscale covers. `state` is sent on play/pause
and about every 400 ms during playback.

## Files

| File | Install location |
|---|---|
| `spicetify/lyrics-bridge.js` | `~/.config/spicetify/Extensions/lyrics-bridge.js` |
| `quickshell/shell.qml` | `~/.config/quickshell/lyrics/shell.qml` |
| `quickshell/Constellation.qml` | `~/.config/quickshell/lyrics/Constellation.qml` |
| `quickshell/cava.conf` | `~/.config/quickshell/lyrics/cava.conf` |
| `install.sh` / `uninstall.sh` | copy the files above into place / remove them |
| `docs/bar-button.md` | bar buttons and keybinds |
| `README.md` | user documentation |

## Installing

Run `./install.sh` (`--no-apply` skips `spicetify apply`, `--apply` runs it without asking).
It never uses `sudo`. For a manual check first:

- `pacman -Q quickshell qt6-websockets cava` and `qs --version`
- `spicetify --version` and `spicetify config extensions`
- `echo $XDG_CURRENT_DESKTOP` should be Hyprland

Autostart goes in the user's Hyprland config (`exec-once = qs -c lyrics`, or the Lua
equivalent). Show the user the line and where it goes before editing.

## Working on it

- After changing QML: `./install.sh --no-apply`, or copy the files and restart with
  `pkill -f "^qs -c lyrics"; qs -c lyrics > /tmp/lyrics-qs.log 2>&1 &`.
  Keep the `^` anchor: without it `pkill -f` also matches the shell running the command.
- Hot reload is disabled on purpose (`Quickshell.watchFiles = false`): a reload starts a second
  WebSocket server while the old one still holds the port.
- After changing the extension: copy it and run `spicetify apply`. This restarts Spotify, so
  ask the user first.
- A restart re-reads the state file and may open fullscreen. Note the mode before restarting
  (`qs -c lyrics ipc call lyrics isFullscreen`) and restore it afterwards.
- MPRIS test without disturbing the screen: run a copy of the config with another `port`,
  another state file and a tiny window (`qs -p <copy>/shell.qml`) against a fake MPRIS player.
- QML's JS engine lacks some newer features (`String.matchAll`, `padStart`): avoid them.
- Protocol test without Spotify: send a fake `track` and a `state` message with
  `playing: true` over the WebSocket.

## Debugging

- **Log:** `/tmp/lyrics-qs.log` when started as above. Each song prints
  `lyrics track: … | source: … | lines: … | colors: …`.
- **QML module `QtWebSockets` not found** → `qt6-websockets` missing, or Quickshell needs a
  rebuild after a Qt update.
- **Port in use** → change `port` in `shell.qml` and `PORT` in `lyrics-bridge.js`.
- **Nothing arrives from Spotify** → check `spicetify apply` was run; `spicetify enable-devtools`,
  restart Spotify, check the console for `lyrics-bridge` errors.
- **No lyrics for a song** → `source: none` means no source had synced lyrics.
- **Lyrics early/late** → `offsetMs` in `shell.qml` (+ = earlier).
- **Nothing reacts to the music** → cava hears silence when Spotify plays on another device.
  `qs -c lyrics ipc call lyrics mood` prints mood, dyn, beat count and energy.
- **Lyrics freeze** → the Timer clock must stay; a FrameAnimation alone stalls when the
  compositor stops requesting frames.
- **Quickshell API differences** between versions → check https://quickshell.org/docs/ for the
  installed version; don't guess.

## Settings (top of shell.qml)

`offsetMs`, `accent`, `fontFamily`, `fontSize` (96), `musicReactive`, `beatPulse`,
`dynamicColor`, `runningBorder`, `borderSpeedMs`, `borderWidth`, `borderGlow`, `immersive`,
`beatBorder`, `particleReact`, `ghostStars`, `dynamics`, `ambientMonitors`, `moodAdaptive`,
`bounceBeat`, `idleHideMs`, `interludeCard`, `interludeMinMs`, `anyPlayer`, `startFullscreen`, `port`. The README table explains each.

## Possible improvements (only if the user asks)

- Use Spotify's own `SYLLABLE_SYNCED` lyrics or enhanced LRC word tags when present.
- A separate timing offset for Bluetooth outputs.
- Choose the monitor, or follow the focused one.

## Rules

- Never delete or overwrite the user's existing configs; back up a file before editing it.
- Ask before using `sudo`, installing AUR packages, or restarting Spotify.
- Never commit `*.secret` files or core dumps (both are in `.gitignore`).
- Don't push; the user reviews and pushes.
