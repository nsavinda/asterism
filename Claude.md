# Project: Lyric Immersive (Spicetify → Quickshell)

You are working on the user's own machine. Your job is to install, configure, test and
debug a desktop lyrics visualizer. Work step by step, verify each step, and fix problems
yourself where you can. Ask the user only when you need them to do something physical
(e.g. play a song, look at the screen).

## System

- OS: Arch Linux
- Compositor: Hyprland (Wayland)
- Shell/widgets: Quickshell (QML)
- Spotify client patched with Spicetify

## What we are building

A "constellation" lyrics effect shown on the desktop while Spotify plays:

- Each lyric word appears as a star (✦) in time with the song.
- Stars of the current line are connected by thin lines, drawn as each word arrives.
- The current word is large, white, with an accent-colour glow; earlier words shrink and dim.
- When the next lyric line starts, the old constellation fades out and a new one fades in
  at a slightly different position.
- Optional soft purple glow around the screen edges while music plays.
- Overlay is click-through, sits on the desktop (above wallpaper, below windows).

## Architecture

```
Spotify + Spicetify extension (lyrics-bridge.js)
   │  lyrics, in order:
   │   1. Spicy Lyrics' local cache (if installed; CacheStorage "SpicyLyrics_LyricsStore_g1",
   │      read-only, no extra requests) → real word timing for "Syllable" songs
   │   2. Spotify color-lyrics API  3. LRCLIB (lrclib.net)
   │  line-synced sources: line timings → estimated word timings
   │  if Spicy's cache fills after we sent another source, upgrades within ~10 s
   │  sends JSON over WebSocket ws://127.0.0.1:8975
   ▼
Quickshell config "lyrics" (shell.qml + Constellation.qml)
   • QtWebSockets WebSocketServer on 127.0.0.1:8975
   • interpolates playback position with a 16 ms timer
   • PanelWindow on WlrLayer.Bottom, mask: Region {} (click-through)
```

### Message protocol (extension → Quickshell)

```json
{ "type": "track", "id": "...", "title": "...", "artist": "...", "source": "spotify|lrclib|none",
  "lines": [ { "t": 12340, "end": 15800, "words": [ { "text": "hello", "t": 12340 } ] } ] }

{ "type": "state", "position": 12500, "playing": true }
```

Times are milliseconds. `state` is sent on play/pause and about every 400 ms during playback.

## Files in this folder

| File | Install location |
|---|---|
| `spicetify/lyrics-bridge.js` | `~/.config/spicetify/Extensions/lyrics-bridge.js` |
| `quickshell/shell.qml` | `~/.config/quickshell/lyrics/shell.qml` |
| `quickshell/Constellation.qml` | `~/.config/quickshell/lyrics/Constellation.qml` |
| `quickshell/cava.conf` | `~/.config/quickshell/lyrics/cava.conf` (music-reactive size; needs `cava`) |
| `install.sh` / `uninstall.sh` | copy the files above into place / remove them (`--no-apply` skips `spicetify apply`) |
| `docs/bar-button.md` | how to add bar buttons and keybinds |
| `README.md` | user documentation |

If any of these files are missing, stop and tell the user which ones to add to the folder.

## Tasks (do in order, check each before moving on)

### 1. Check the environment
- `pacman -Q quickshell quickshell-git qt6-base qt6-websockets 2>/dev/null` and `qs --version`
- `spicetify --version` and `spicetify config extensions`
- `echo $XDG_CURRENT_DESKTOP` should be Hyprland
- Report what's missing before installing anything.

### 2. Install missing dependencies
- `sudo pacman -S --needed qt6-websockets`
- If Quickshell is missing, install it from the AUR (`yay -S quickshell` or `paru -S quickshell`).
  Ask the user before running AUR installs.

### 3. Install the Spicetify extension
```bash
mkdir -p ~/.config/spicetify/Extensions
cp spicetify/lyrics-bridge.js ~/.config/spicetify/Extensions/
spicetify config extensions lyrics-bridge.js
spicetify apply
```
Don't remove the user's existing extensions. `spicetify config extensions X` adds to the list.

### 4. Install the Quickshell config
```bash
mkdir -p ~/.config/quickshell/lyrics
cp quickshell/shell.qml quickshell/Constellation.qml quickshell/cava.conf ~/.config/quickshell/lyrics/
```
Do not touch the user's existing Quickshell config (`~/.config/quickshell/shell.qml` or
other subfolders). This runs as a separate config.

### 5. Test run
- Start it in the background and capture logs: `qs -c lyrics > /tmp/lyrics-qs.log 2>&1 &`
- Check the port is listening: `ss -ltnp | grep 8975`
- Ask the user to play a song with lyrics in Spotify, then read `/tmp/lyrics-qs.log`.
- Optional protocol test without Spotify (needs `websocat`, or a short Python script using
  the `websockets` package): send a fake `track` message and a `state` message with
  `playing: true` and confirm stars appear.

### 6. Debugging guide
- **QML module not found `QtWebSockets`** → `qt6-websockets` missing, or a Qt version
  mismatch with quickshell-git; rebuild Quickshell after Qt updates.
- **Port in use** → change `port` in `shell.qml` AND `PORT` in `lyrics-bridge.js`.
- **Nothing arrives from Spotify** → run `spicetify enable-devtools`, restart Spotify,
  open devtools (Ctrl+Shift+I), check the console for errors from lyrics-bridge.js.
- **Which source was used** → `source` in `/tmp/lyrics-qs.log`: `spicy-syllable` (real word
  timing), `spicy-line`, `spotify`, `lrclib`, or `none`.
- **No lyrics for a song** → check the `source` field. Spotify's lyrics endpoint may fail;
  the LRCLIB fallback needs a song that exists on lrclib.net.
- **Lyrics early/late** → adjust `offsetMs` in `shell.qml` (+ = earlier).
- **Overlay not visible** → windows cover WlrLayer.Bottom. Test on an empty workspace,
  or temporarily set `WlrLayer.Overlay`.
- **Overlay blocks clicks** → make sure `mask: Region {}` is on the PanelWindow.
- **Quickshell API differences** between versions (e.g. `WlrLayershell`, `ExclusionMode`,
  `PanelWindow` props) → check the installed version's docs at https://quickshell.org/docs/
  and adapt the code; don't guess.

### 7. Autostart
Add to the user's Hyprland config (find the right file, it may be split into sources):
```ini
exec-once = qs -c lyrics
```
Show the user the line and where you're adding it before editing.

## Settings the user may ask to change (top of shell.qml)

- `offsetMs`: timing offset
- `accent`: star/glow colour (default `#b388ff`)
- `fontFamily`: check installed fonts with `fc-list : family | sort -u`
- `fontSize`: current word size in px (default 72)
- `musicReactive`, `beatPulse`: words grow with the music via cava (beat pulse + loud/quiet size)
- `ghostStars`: faint star shows where the next word will land (anticipation)
- `dynamics`: effects scale with how far the music is above its ~17 s loudness baseline
- `ambientMonitors`: fullscreen only, soft colour glow on the edges of the other monitors
- `moodAdaptive`: calm vs energetic (bass onsets per second + loudness) shapes word animation,
  particles, backdrop brightness/saturation and border speed
- `bounceBeat`: beat pulse rises and falls like a bounce instead of an instant flash
- `idleHideMs`: fullscreen hides the cursor and "Esc to exit" hint after this long without mouse movement
- Debug: `qs -c lyrics ipc call lyrics mood` prints mood, dyn, beat count and energy
- `dynamicColor`: take colours from the album art (else `accent`)
- `runningBorder`, `borderSpeedMs`, `borderWidth`: light running around the screen edge
- `WlrLayershell.layer`: `WlrLayer.Bottom` (desktop) or `WlrLayer.Overlay` (over windows)
- `screen:`: pin to one monitor (`Quickshell.screens[i]`), or wrap in `Variants` for all monitors

## Possible improvements (only if the user asks)

- Real word-level timing from enhanced LRC (`<mm:ss.xx>` word tags) or Spotify
  `SYLLABLE_SYNCED` lyrics instead of estimated word times.
- Show the song title/artist faintly during instrumental breaks.
- Take the accent colour from the album art (Spicetify `Spicetify.colorExtractor`).
- Keyboard shortcut to toggle: Hyprland `bind` + a Quickshell `IpcHandler` called via `qs ipc`.

## Rules

- Never commit `*.secret` files or core dumps (both are in `.gitignore`).

- Never delete or overwrite the user's existing configs; back up a file before editing it
  (`cp file file.bak`).
- Ask before using `sudo` or installing AUR packages.
- After changing QML, restart with `pkill -f "qs -c lyrics"; qs -c lyrics &` and check the log.
- After changing the extension, re-copy it and run `spicetify apply`.
