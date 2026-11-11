#!/bin/sh
# Installs Braincell for this user. Usage: ./install.sh [pairing-code]
#
# Run it with no code on the first Mac to get one, then with that code on the second.
# Running it again upgrades in place and keeps the existing code.
set -eu
cd "$(dirname "$0")"

home="$HOME/.braincell"
label="com.braincell.agent"
plist="$HOME/Library/LaunchAgents/$label.plist"

command -v swiftc >/dev/null || { echo "Braincell needs the Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Braincell needs python3 (it comes with the Xcode Command Line Tools)." >&2; exit 1; }
swift=$(swiftc --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)
major=${swift% *}; minor=${swift#* }
if [ -n "$swift" ] && { [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 9 ]; }; }; then
  echo "Braincell needs Swift 5.9 or later (found $major.$minor). Update the Command Line Tools in Software Update." >&2; exit 1
fi

# Settings: what was passed in, else what's already installed, else defaults.
saved() { [ -f "$home/config.json" ] && sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$home/config.json" || true; }
room="${1:-$(saved room)}"
[ -n "$room" ] || room=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 20)
case "$room" in *[!A-Za-z0-9_-]*) echo "A pairing code can only contain letters, digits, - and _." >&2; exit 1 ;; esac
id=$(saved id)
[ -n "$id" ] || id=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 8)
server="${BRAINCELL_SERVER:-$(saved server)}"
[ -n "$server" ] || server="https://ntfy.sh"

echo "Building Braincell…"
mkdir -p "$home/busy" "$(dirname "$plist")"
swiftc -O -swift-version 5 Braincell.swift -o "$home/Braincell"
cp hook hooks.py uninstall.sh "$home/"
chmod +x "$home/hook" "$home/uninstall.sh"
xattr -dr com.apple.quarantine "$home" 2>/dev/null || true   # a copy that came from a zip or AirDrop carries a download flag
printf '{\n  "server": "%s",\n  "room": "%s",\n  "id": "%s"\n}\n' "$server" "$room" "$id" > "$home/config.json"

python3 "$home/hooks.py" add

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$home/Braincell</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || { sleep 2; launchctl bootstrap "gui/$(id -u)" "$plist"; }

echo
echo "Braincell is running and will start at login."
echo "Pairing code: $room"
echo "Your friend installs with:  ./install.sh $room"
echo "Hooks apply to Claude Code sessions started from now on."
