#!/usr/bin/env python3
"""Add or remove Braincell's hooks in ~/.claude/settings.json.

Usage: hooks.py add|remove

Other hooks are left alone: Braincell's entries are appended next to them, and
removal deletes only entries whose command runs ~/.braincell/hook. Each entry does
nothing on a Mac where Braincell isn't installed, so a synced settings.json is safe.
"""
import json
import os
import shutil
import sys

SETTINGS = os.environ.get("BRAINCELL_SETTINGS") or os.path.expanduser("~/.claude/settings.json")
MARK = ".braincell/hook"


def entry(action, background=False, matcher=None):
    command = f"test -x ~/.braincell/hook && ~/.braincell/hook {action} || true"
    hook = {"type": "command", "command": command, "timeout": 5}
    if background:
        hook["async"] = True
    group = {"hooks": [hook]}
    if matcher:
        group["matcher"] = matcher
    return group


WANTED = [
    ("SessionStart", entry("model", background=True)),             # which model: a new one gets a sparkle
    ("UserPromptSubmit", entry("busy")),                           # a turn starts
    ("PreToolUse", entry("tool", background=True)),                # which tool, and what for
    ("PostToolUse", entry("beat", background=True)),               # heartbeat after long tools
    ("PreCompact", entry("tidy", background=True)),                # Claude is compacting its context
    ("Notification", entry("wait", matcher="permission_prompt")),  # Claude is asking for permission
    ("Notification", entry("wait", matcher="elicitation_dialog")),
    ("Stop", entry("idle")),                                       # the turn ended
    ("StopFailure", entry("fail")),                                # the turn died on an API error
    ("SessionEnd", entry("quit")),
    ("Notification", entry("quit", matcher="idle_prompt")),        # backstop: Esc fires no Stop
]


def ours(group):
    return any(MARK in h.get("command", "") for h in group.get("hooks", []))


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("add", "remove"):
        sys.exit(__doc__)

    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            text = f.read()
        try:
            settings = json.loads(text) if text.strip() else {}
        except json.JSONDecodeError as e:
            sys.exit(f"{SETTINGS} is not valid JSON ({e}); leaving it untouched.")
        if not isinstance(settings, dict):
            sys.exit(f"{SETTINGS} is not a JSON object; leaving it untouched.")
    elif action == "remove":
        return

    hooks = settings.get("hooks") or {}
    for event in list(hooks):
        hooks[event] = [g for g in hooks[event] if not ours(g)]
        if not hooks[event]:
            del hooks[event]
    if action == "add":
        for event, group in WANTED:
            hooks.setdefault(event, []).append(group)
    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    backup = SETTINGS + ".before-braincell"
    if action == "add" and os.path.exists(SETTINGS) and not os.path.exists(backup):
        shutil.copy2(SETTINGS, backup)
    tmp = SETTINGS + ".braincell-tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, SETTINGS)


if __name__ == "__main__":
    main()
