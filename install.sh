#!/bin/sh
# Installs Braincell for this user. Usage: ./install.sh [pairing-code | new]
#
# Braincell pairs two Macs. Run it with no code on the first to get one, then with that code on
# the second. Running it again upgrades in place and keeps the code; "new" starts a fresh pair.
set -eu
cd "$(dirname "$0")"

home="$HOME/.braincell"
label="com.braincell.agent"
plist="$HOME/Library/LaunchAgents/$label.plist"
repo="https://github.com/Aeronyx/braincell"

[ $# -le 1 ] || { echo "Usage: install.sh [pairing-code]   (a code is one word: check for a stray space)" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "Braincell needs the Xcode Command Line Tools: xcode-select --install" >&2; exit 1; }
command -v python3 >/dev/null || { echo "Braincell needs python3 (it comes with the Xcode Command Line Tools)." >&2; exit 1; }
swift=$(swiftc --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)
major=${swift% *}; minor=${swift#* }
if [ -n "$swift" ] && { [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 9 ]; }; }; then
  echo "Braincell needs Swift 5.9 or later (found $major.$minor). Update the Command Line Tools in Software Update." >&2; exit 1
fi

# Settings: what was passed in, else what's already installed, else defaults.
saved() { [ -f "$home/config.json" ] && sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" "$home/config.json" || true; }
before=$(saved room)
case "${1:-}" in
  "") room=$before ;;
  new) room="" ;;
  *) room=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
     case "$room" in *[!a-z0-9]*) room="" ;; esac
     if [ ${#room} -ne 20 ]; then
       echo "That isn't a pairing code. A code is 20 letters and digits: the one install.sh printed on your friend's Mac." >&2
       echo "To start a pair instead, run install.sh with nothing after it, and send your friend the line it prints." >&2
       exit 1
     fi ;;
esac
[ -n "$room" ] || room=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 20)
id=$(saved id)
case "$id" in *[!a-f0-9]*) id="" ;; esac
[ -n "$id" ] || id=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 8)
server="${BRAINCELL_SERVER:-$(saved server)}"
[ -n "$server" ] || server="https://ntfy.sh"
case "$server" in
  *[!A-Za-z0-9.:/_~%-]*) echo "BRAINCELL_SERVER should be a plain address, like https://ntfy.example.com" >&2; exit 1 ;;
  http://*|https://*) ;;
  *) echo "BRAINCELL_SERVER should start with https://" >&2; exit 1 ;;
esac

echo "Building Braincell…"
mkdir -p "$home/busy" "$(dirname "$plist")"
chmod 700 "$home"      # the pairing code inside is for this account only
swiftc -O -swift-version 5 Braincell.swift -o "$home/Braincell"
cp hook hooks.py uninstall.sh version "$home/"
chmod +x "$home/hook" "$home/uninstall.sh"
xattr -dr com.apple.quarantine "$home" 2>/dev/null || true   # a copy that came from a zip or AirDrop carries a download flag
printf '{\n  "server": "%s",\n  "room": "%s",\n  "id": "%s"\n}\n' "$server" "$room" "$id" > "$home/config.json"
chmod 600 "$home/config.json"
[ "$room" = "$before" ] || rm -f "$home/paired"      # a different code is a different friend

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

curl -fsS -m 5 -o /dev/null "$server/v1/health" 2>/dev/null ||
  echo "Note: $server can't be reached right now. The twins will show up once it can."

echo
echo "Braincell is running and will start at login. The twins come out when you and your friend are both working."
if [ -n "$before" ] && [ "$room" != "$before" ]; then echo "This Mac now pairs with a different code than before."; fi
echo
echo "Braincell pairs two Macs: yours and one friend's. Your friend pastes this line into Terminal."
echo "It carries your pairing code, so treat it like a password:"
echo
echo "  d=\$(mktemp -d) && git clone --depth 1 $repo \"\$d\" && \"\$d/install.sh\" $room; rm -rf \"\$d\""
echo
echo "See the twins now: ~/.braincell/Braincell --demo"
echo "Claude Code sessions that are already open may need a restart to count."
