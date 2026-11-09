# AirDeck

Control your Linux PC from your Android phone over Wi-Fi.

- **Touchpad**: tap to click, two-finger tap to right-click, two-finger drag to scroll
- **Air mouse**: move the cursor by pointing and turning the phone (gyroscope)
- **Hold to talk**: walkie-talkie voice in both directions, phone ↔ PC
- **Keyboard**: type on the PC from the phone keyboard, plus shortcut keys (copy, paste, Alt+Tab, media, volume)
- **Easy pairing**: scan a QR code once; after that the phone reconnects by itself

## Layout

| Path | What it is |
| --- | --- |
| `server/airdeck_server.py` | PC server (Python 3, no extra packages) |
| `server/qrcode.min.js` | QR code library used by the PC page ([qrcodejs](https://github.com/davidshimjs/qrcodejs), MIT) |
| `app/` | Android app (Flutter) |
| `install.sh` | Adds the app-menu entry and start-at-login for the PC server |

## PC setup (Linux)

Needs Python 3, PipeWire (`pw-cat`) for voice, and write access to `/dev/uinput` for mouse and keyboard control. Works on Wayland and X11.

```bash
./install.sh            # menu entry + start at login, starts it now
./install.sh --uninstall
```

Or run it directly:

```bash
python3 server/airdeck_server.py            # opens the PC page with the QR code
python3 server/airdeck_server.py --show-code
```

The PC page (http://127.0.0.1:47802) shows the QR code, the connected phones and a **Hold to talk** button. You can also hold Space on that page to talk.

If `/dev/uinput` is not writable for your user, add a udev rule:

```bash
echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/60-airdeck-uinput.rules
sudo usermod -aG input "$USER"   # then log out and back in
```

## Phone app

```bash
cd app
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Open AirDeck on the phone, tap **Scan QR code** and point it at the PC page. The phone and the PC must be on the same Wi-Fi network, or the PC must be connected to the phone's hotspot.

## Network

| Port | Protocol | Use |
| --- | --- | --- |
| 47800 | TCP | control and voice |
| 47801 | UDP | discovery |
| 47802 | TCP, localhost only | PC page |

A 6-digit connection code protects the connection. It is stored in `~/.config/airdeck/config.json`; delete that file to get a new code. Traffic is not encrypted, so use AirDeck only on networks you trust.
