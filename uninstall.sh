#!/bin/sh
# Removes Braincell from this Mac: its Claude Code hooks, its login item, and ~/.braincell.
home="$HOME/.braincell"
label="com.braincell.agent"

python3 "$(dirname "$0")/hooks.py" remove ||
  echo "Couldn't edit ~/.claude/settings.json: delete the entries that mention .braincell/hook by hand."
defaults delete Braincell 2>/dev/null     # where macOS remembers the menu bar item
rm -f "$HOME/Library/Preferences/Braincell.plist" "$HOME/Library/LaunchAgents/$label.plist"
rm -f "$HOME/.claude/settings.json.before-braincell"
rm -rf "$home"
echo "Braincell removed."

# Last, because stopping the app also ends this script when the app's menu started it.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
exit 0
