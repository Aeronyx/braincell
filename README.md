# Braincell

Two little peekers in your Mac's menu bar who share one braincell. They pop up while you and a
friend are both mid-turn in Claude Code, act out what each Claude is doing, and nap when one of
you stops.

![The twins on a light and a dark menu bar](twins.gif)

## Install

Needs macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`) and Claude Code.

```bash
git clone --depth 1 https://github.com/Aeronyx/braincell /tmp/braincell && /tmp/braincell/install.sh; rm -rf /tmp/braincell
```

It prints a pairing code. Your friend runs the same line with the code added after `install.sh`.
Run it again any time to update; it keeps your code. To see the twins without a friend:

```bash
~/.braincell/Braincell --demo
```

## What they do

Yours is the solid one on the left. Your friend's is the outlined one on the right.

| Claude is | Its twin |
| --- | --- |
| thinking | gazes up |
| reading or searching | sweeps its eyes along the lines |
| writing or editing | types |
| running commands | hops |
| browsing the web | looks all around |
| planning | tilts its head |
| running subagents | conducts |
| waiting on you | leans out and waves |
| done with a to-do item | throws its paws up |

The braincell goes to whoever switched tasks last, and they share it while both do the same kind
of work. Whoever stops nods off and the other keeps the braincell. After five minutes asleep,
they leave.

Click them to read what each Claude is up to ("adding custom widgets…") and how long you've
worked together today, or to line them up with your other icons instead of sitting on the bar's
bottom edge.

## Is it safe?

Claude Code hooks tell a tiny menu bar app when your turn starts and stops, and the app tells
your friend's app through a relay. That is all of it: about 1,200 lines you can read in one
sitting (one Swift file, a 30-line shell hook, an installer and an uninstaller). Nothing arrives
prebuilt. It compiles on your Mac.

- **No account, analytics, auto-update or admin rights.**
- **Your prompts, code and commands never leave your Mac,** and Braincell never stores them.
- **It sends one line,** such as
  `{"id":"a1b2c3d4","busy":true,"doing":"write","label":"adding custom widgets","ticked":2}`:
  whether you're busy, the kind of work, a few words from Claude's own to-do list or command
  description, and how many to-do items are done. The line is encrypted with a key made from your
  pairing code, so only your friend can read it. It travels through [ntfy.sh](https://ntfy.sh),
  which sees neither the code nor the contents. Untick "Share what I'm working on" to leave the
  words out.
- **It installs** `~/.braincell`, a login item, and its hooks in `~/.claude/settings.json`, next
  to any you already have. Removing it takes all three out.
- **It costs** 0% CPU and about 15 MB of memory while hidden, about 2% of one core while the
  twins are out, and no tokens: the hooks print nothing.

## Remove

Click the twins and choose "Remove Braincell…", or run `~/.braincell/uninstall.sh`.

## Good to know

- Tested on macOS 26 with Apple Silicon and one display. The build is also checked for macOS 13
  and Intel. With several displays, expect the twins only in the active display's menu bar.
- Only Claude Code sessions on your Mac count, not cloud sessions.
- A turn you interrupt with Esc can count as busy for up to 15 minutes.
- ntfy.sh allows 250 messages a day, so your friend hears what you're doing at most once a
  minute. To use your own ntfy server, put `BRAINCELL_SERVER=https://ntfy.example.com` in front
  of `/tmp/braincell/install.sh` on both Macs.
- If the twins ever stop showing up, run the install line again.

[MIT](LICENSE) licensed. Not affiliated with Anthropic.
