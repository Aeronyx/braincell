# Braincell

<p align="center">
  <img src="twins.gif" alt="The twins on a light and a dark menu bar" width="700">
</p>

Two little peekers in your Mac's menu bar who share one braincell. They pop up while you and a
friend are both mid-turn in Claude Code, quietly act out what each Claude is doing, and nap when
one of you stops. Braincell is for exactly two people (for now): you and one friend.

## Install

Needs macOS 13 or later, the Xcode Command Line Tools (`xcode-select --install`) and Claude Code.

```bash
d=$(mktemp -d) && git clone --depth 1 https://github.com/Aeronyx/braincell "$d" && "$d/install.sh"; rm -rf "$d"
```

It prints a line for your friend to paste, with your pairing code in it. One code pairs two
Macs, yours and theirs, so they need that line and not the one above (which would hand them a
code of their own). Run the line above again any time to update; it keeps your code. To see the
twins without a friend:

```bash
~/.braincell/Braincell --demo
```

Nothing shows until you're both working. If a third Mac ever turns up on your code, the twins'
menu says so; add `new` after `install.sh` to start over with a fresh code.

## What they do

Yours is the solid one on the left. Your friend's is the outlined one on the right. Mostly they
sit still and watch the braincell. Now and then each acts out its Claude's work:

| Claude is | Its twin |
| --- | --- |
| thinking | gazes up |
| reading or searching | lets its eyes travel along the lines |
| writing or editing | taps its paws |
| running commands | leans in and narrows its eyes |
| browsing the web | looks all around |
| planning | tilts its head |
| running subagents | conducts |
| waiting on you | leans out and waves, then gets bored |
| compacting its context | squeezes itself down |

The braincell drifts to whoever switched tasks last, and they share it while both do the same
kind of work. Whoever stops flicks it over and nods off. After five minutes asleep, they leave.

Some things are rarer:

- A finished to-do item makes a twin's eyes smile.
- One twin reaches over and takes the braincell off the other's head, or it bounces off a head.
- A long nap ends with a yawn, and a long stint with a stretch.
- After an hour apart, they lean in for a hug.
- Every hour you've worked together today earns a high five.
- After four hours of work in a day, a twin gets droopy and snores bigger Z's.
- On the first day with a new Claude model, the braincell sparkles.
- Out of usage, a twin slumps with crossed-out eyes and sweats until its Claude works again.

(And some easter egg animations exist.)

The demo plays most of these in under two minutes. Click the twins to read what each Claude is
up to ("adding custom widgets…") and how long you've worked together today, or to line them up
with your other icons instead of sitting on the bar's bottom edge.

Want yours around all the time? Untick "Disappear when idle" in the same menu. Your twin then
stays out on its own: asleep while you're not working, and otherwise juggling the braincell,
bouncing it on its head and looking around for its friend, until they show up and it shuffles
over to make room. Each of you chooses for your own Mac.

## Is it safe?

Claude Code hooks tell a tiny menu bar app when your turn starts and stops, and the app tells
your friend's app through a relay. That is all of it: about 1,900 lines you can read in one
sitting (one Swift file, a 40-line shell hook, an installer and an uninstaller). Nothing arrives
prebuilt. It compiles on your Mac.

- **No account, analytics, auto-update or admin rights.**
- **Your prompts, code and commands never leave your Mac,** and Braincell never stores them.
- **It sends one line,** such as
  `{"id":"a1b2c3d4","busy":true,"doing":"write","label":"adding custom widgets","ticked":2}`:
  whether you're busy, the kind of work, a few words from Claude's own to-do list or command
  description, how many to-do items are done, a mood when there is one (worn out, on a new
  model, out of usage), and a cue that lets an easter egg play on both Macs at once. Untick
  "Share what I'm working on" to leave the words out.
- **Only your friend can read it.** The line is encrypted with a key made from your pairing
  code, which never leaves your Macs. It travels through [ntfy.sh](https://ntfy.sh), which can
  see that your Mac sent something and when, but not what it says. To use your own ntfy server,
  put `BRAINCELL_SERVER=https://…` right before `"$d/install.sh"`.
- **It installs** `~/.braincell` (readable only by your account), a login item, and its hooks in
  `~/.claude/settings.json`, next to any you already have. Removing it takes all three out.
- **It costs** no tokens (the hooks print nothing), under 15 MB of memory, and next to no CPU:
  0% while the twins are hidden or sound asleep, and under 1% of one core while they're up.

## Remove

Click the twins and choose "Remove Braincell…", or run `~/.braincell/uninstall.sh`.

[MIT](LICENSE) licensed. Not affiliated with Anthropic.
