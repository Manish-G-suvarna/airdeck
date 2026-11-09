#!/usr/bin/env bash
# Installs the AirDeck PC server for the current user:
#  - app menu entry ("AirDeck")
#  - start automatically at login (in the background)
# Run again any time; it is safe to repeat. Use --uninstall to remove.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$DIR/server/airdeck_server.py"
APPS="$HOME/.local/share/applications"
AUTO="$HOME/.config/autostart"

if [[ "${1:-}" == "--uninstall" ]]; then
    pkill -f "airdeck_server.py" || true
    rm -f "$APPS/airdeck.desktop" "$AUTO/airdeck.desktop"
    echo "AirDeck removed from the menu and login items."
    exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
command -v pw-cat >/dev/null || echo "warning: pw-cat (PipeWire) not found, push-to-talk will not work"
[[ -w /dev/uinput ]] || echo "warning: /dev/uinput is not writable, mouse control will not work (see README)"

chmod +x "$SERVER"
mkdir -p "$APPS" "$AUTO" "$HOME/.local/share/icons/hicolor/scalable/apps"
cp "$DIR/assets/airdeck.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/airdeck.svg"

cat > "$APPS/airdeck.desktop" <<EOF
[Desktop Entry]
Name=AirDeck
Comment=Control this PC from your phone (touchpad, air mouse, push-to-talk)
Exec=python3 "$SERVER"
Icon=airdeck
Type=Application
Categories=Utility;
Terminal=false
EOF

cat > "$AUTO/airdeck.desktop" <<EOF
[Desktop Entry]
Name=AirDeck (background)
Exec=python3 "$SERVER" --no-browser
Icon=airdeck
Type=Application
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

# start it now if it isn't running
if ! pgrep -f "airdeck_server.py" >/dev/null; then
    setsid nohup python3 "$SERVER" --no-browser >/dev/null 2>&1 &
fi

echo "AirDeck installed. It starts at login."
echo "Open 'AirDeck' from the app menu to see the QR code for your phone."
