# Adding bar buttons

Asterism is controlled in two ways, so any bar can drive it:

- **IPC commands**, for buttons that only need to *do* something:
  ```bash
  qs -c lyrics ipc call lyrics toggle       # lyrics on / off
  qs -c lyrics ipc call lyrics fullscreen   # fullscreen on / off
  ```
- **A state file**, for a button that also needs to *show* whether lyrics are on:
  `~/.local/state/lyrics-constellation` contains `1` (on) or `0` (off). A missing file means on.
  The overlay watches this file, so writing to it toggles the overlay, and reading it gives you the icon state.

## Waybar

```jsonc
"custom/lyrics": {
    "exec": "[ \"$(cat ~/.local/state/lyrics-constellation 2>/dev/null)\" = 0 ] && echo '󰝛' || echo '󰎈'",
    "interval": 2,
    "on-click": "qs -c lyrics ipc call lyrics toggle",
    "on-click-right": "qs -c lyrics ipc call lyrics fullscreen",
    "tooltip": false
}
```

## A Quickshell bar

Add this to the component that holds your buttons (it needs `import Quickshell` and `import Quickshell.Io`):

```qml
property bool lyricsOn: true

FileView {
    id: lyricsState
    path: Quickshell.env("HOME") + "/.local/state/lyrics-constellation"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: lyricsOn = text().trim() !== "0"
    onLoadFailed: lyricsOn = true
}

function toggleLyrics() {
    lyricsOn = !lyricsOn
    lyricsState.setText(lyricsOn ? "1" : "0")
}

function toggleLyricsFullscreen() {
    Quickshell.execDetached(["qs", "-c", "lyrics", "ipc", "call", "lyrics", "fullscreen"])
}
```

Then call `toggleLyrics()` and `toggleLyricsFullscreen()` from your own button components, and use
`lyricsOn` to pick the icon.

## end-4 / illogical-impulse (`ii`) bar

In `modules/ii/bar/UtilButtons.qml`, put the block above inside the root `Item`, replacing `lyricsOn`
with `root.lyricsOn` in the handlers, and add two buttons inside the `Flow`, next to the existing ones:

```qml
Loader {
    active: true
    visible: active
    sourceComponent: CircleUtilButton {
        onClicked: root.toggleLyrics()
        MaterialSymbol {
            horizontalAlignment: Qt.AlignHCenter
            fill: root.lyricsOn ? 1 : 0
            text: root.lyricsOn ? "lyrics" : "music_off"
            iconSize: Appearance.font.pixelSize.large
            color: root.contentColor
        }
    }
}
Loader {
    active: true
    visible: active
    sourceComponent: CircleUtilButton {
        onClicked: root.toggleLyricsFullscreen()
        MaterialSymbol {
            horizontalAlignment: Qt.AlignHCenter
            fill: 0
            text: "fullscreen"
            iconSize: Appearance.font.pixelSize.large
            color: root.contentColor
        }
    }
}
```

Back up the file first; a dotfiles update will overwrite the change.

## A keybind instead

Hyprland (`hyprland.conf`):

```ini
bind = SUPER, L, exec, qs -c lyrics ipc call lyrics fullscreen
```
