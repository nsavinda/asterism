#!/usr/bin/env bash
# Lyric Immersive installer.
# Copies the Quickshell config and the Spicetify extension into your home directory.
# Never uses sudo and never edits your compositor or bar config.
#
#   ./install.sh            install / update, ask before restarting Spotify
#   ./install.sh --apply    also run `spicetify apply` without asking (restarts Spotify)
#   ./install.sh --no-apply never run `spicetify apply`
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/lyrics"
APPLY="ask"
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY="yes" ;;
        --no-apply) APPLY="no" ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- dependencies ----------
say "Checking dependencies"
missing=()
command -v qs >/dev/null 2>&1        || missing+=("quickshell (provides 'qs')")
command -v spicetify >/dev/null 2>&1 || missing+=("spicetify")
command -v cava >/dev/null 2>&1      || warn "cava not found: lyrics still work, but nothing will react to the music"
if command -v pacman >/dev/null 2>&1; then
    pacman -Q qt6-websockets >/dev/null 2>&1 || missing+=("qt6-websockets")
fi
if command -v fc-match >/dev/null 2>&1; then
    fc-match -f '%{family[0]}' Inter 2>/dev/null | grep -qi '^Inter' \
        || warn "font 'Inter' not installed: a fallback font will be used (Arch: inter-font)"
fi
if [ "${#missing[@]}" -gt 0 ]; then
    printf '  missing: %s\n' "${missing[@]}" >&2
    die "install the missing packages first (Arch: sudo pacman -S quickshell qt6-websockets cava inter-font; spicetify from the AUR or spicetify.app)"
fi

# ---------- copy helper: back up a different existing file once ----------
CHANGED=0   # set to 1 when the last install_file call wrote a new or different file
install_file() {
    local src="$1" dst="$2"
    CHANGED=1
    if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
        cp -p "$dst" "$dst.bak"
        echo "  updated  $dst  (previous version saved as $(basename "$dst").bak)"
    elif [ ! -f "$dst" ]; then
        echo "  new      $dst"
    else
        CHANGED=0
        echo "  current  $dst"
    fi
    install -Dm644 "$src" "$dst"
}

# ---------- Quickshell config ----------
say "Installing the Quickshell config to $QS_DIR"
for f in shell.qml Constellation.qml cava.conf; do
    install_file "$HERE/quickshell/$f" "$QS_DIR/$f"
done

# ---------- Spicetify extension ----------
EXT_DIR="$(dirname "$(spicetify -c)")/Extensions"
say "Installing the Spicetify extension to $EXT_DIR"
install_file "$HERE/spicetify/lyrics-bridge.js" "$EXT_DIR/lyrics-bridge.js"
EXT_CHANGED="$CHANGED"
if spicetify config extensions 2>/dev/null | grep -qx 'lyrics-bridge.js'; then
    echo "  already registered with Spicetify"
else
    spicetify config extensions lyrics-bridge.js >/dev/null
    echo "  registered with Spicetify"
    EXT_CHANGED=1
fi

# nothing new for Spotify to load → no need to restart it
if [ "$EXT_CHANGED" = 0 ] && [ "$APPLY" != "yes" ]; then
    echo "  extension unchanged, skipping 'spicetify apply'"
    APPLY="skip"
fi

if [ "$APPLY" = "ask" ]; then
    if [ -t 0 ]; then
        read -r -p "Run 'spicetify apply' now? This restarts Spotify. [y/N] " ans
        case "$ans" in y|Y|yes) APPLY="yes" ;; *) APPLY="no" ;; esac
    else
        APPLY="no"
    fi
fi
if [ "$APPLY" = "yes" ]; then
    say "Applying Spicetify (Spotify will restart)"
    spicetify apply
elif [ "$APPLY" = "no" ]; then
    warn "Spotify does not load the extension until you run: spicetify apply"
fi

# ---------- (re)start the overlay ----------
say "Starting the overlay"
pkill -f '^qs -c lyrics' 2>/dev/null || true
sleep 0.5
setsid -f qs -c lyrics >/dev/null 2>&1 || warn "could not start 'qs -c lyrics'; run it in a terminal to see the error"

cat <<'EOF'

Done. Play a song with lyrics in Spotify.

  Fullscreen on/off   qs -c lyrics ipc call lyrics fullscreen     (Esc also exits)
  Lyrics on/off       qs -c lyrics ipc call lyrics toggle
  Start at login      Hyprland:  exec-once = qs -c lyrics
                      (Lua config: hl.exec_cmd("qs -c lyrics") inside hl.on("hyprland.start", ...))

Settings are at the top of ~/.config/quickshell/lyrics/shell.qml. See README.md.
EOF
