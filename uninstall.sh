#!/usr/bin/env bash
# Asterism uninstaller. Removes only what install.sh added.
#   ./uninstall.sh            ask before restarting Spotify
#   ./uninstall.sh --apply    run `spicetify apply` without asking (restarts Spotify)
#   ./uninstall.sh --no-apply never run `spicetify apply`
set -euo pipefail

QS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/lyrics"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/lyrics-constellation"
APPLY="ask"
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY="yes" ;;
        --no-apply) APPLY="no" ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }

say "Stopping the overlay"
pkill -f '^qs -c lyrics' 2>/dev/null || true

say "Removing the Quickshell config"
for f in shell.qml LyricView.qml Constellation.qml Karaoke.qml Focus.qml Wave.qml rows.js cava.conf; do
    rm -f "$QS_DIR/$f.bak"
    rm -f "$QS_DIR/$f"
done
rmdir "$QS_DIR" 2>/dev/null || echo "  kept $QS_DIR (it contains other files)"
rm -f "$STATE_FILE" "${XDG_STATE_HOME:-$HOME/.local/state}/asterism-profile"

if command -v spicetify >/dev/null 2>&1; then
    say "Removing the Spicetify extension"
    EXT_DIR="$(dirname "$(spicetify -c)")/Extensions"
    rm -f "$EXT_DIR/lyrics-bridge.js" "$EXT_DIR/lyrics-bridge.js.bak"
    if spicetify config extensions 2>/dev/null | grep -qx 'lyrics-bridge.js'; then
        spicetify config extensions lyrics-bridge.js- >/dev/null   # trailing "-" removes an entry
    fi
    if [ "$APPLY" = "ask" ]; then
        if [ -t 0 ]; then
            read -r -p "Run 'spicetify apply' now? This restarts Spotify. [y/N] " ans
            case "$ans" in y|Y|yes) APPLY="yes" ;; *) APPLY="no" ;; esac
        else
            APPLY="no"
        fi
    fi
    if [ "$APPLY" = "yes" ]; then spicetify apply; else echo "  run 'spicetify apply' to unload it from Spotify"; fi
fi

echo
echo "Removed. If you added an autostart line (qs -c lyrics) or a bar button, remove those by hand."
