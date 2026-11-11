# Braincell

<p align="center">
  <img src="twins.gif" alt="The twins on a light and a dark menu bar" width="700">
</p>

Two little peekers in your Mac's menu bar who share one braincell. They pop up while you and a
friend are both mid-turn in Claude Code, quietly act out what each Claude is doing, and nap when
one of you stops.

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
- Every hour you've worked together today earns a high five.
- After four hours of work in a day, a twin gets droopy and snores bigger Z's.
- On the first day with a new Claude model, the braincell sparkles.
- Out of usage, a twin slumps with crossed-out eyes and sweats until its Claude works again.

The demo plays most of these in about a minute. Click the twins to read what each Claude is up to
("adding custom widgets…") and how long you've worked together today, or to line them up with
your other icons instead of sitting on the bar's bottom edge.

## Is it safe?

Claude Code hooks tell a tiny menu bar app when your turn starts and stops, and the app tells
your friend's app through a relay. That is all of it: about 1,400 lines you can read in one
sitting (one Swift file, a 40-line shell hook, an installer and an uninstaller). Nothing arrives
prebuilt. It compiles on your Mac.

- **No account, analytics, auto-update or admin rights.**
- **Your prompts, code and commands never leave your Mac,** and Braincell never stores them.
- **It sends one line,** such as
  `{"id":"a1b2c3d4","busy":true,"doing":"write","label":"adding custom widgets","ticked":2}`:
  whether you're busy, the kind of work, a few words from Claude's own to-do list or command
  description, how many to-do items are done, and a mood when there is one (worn out, on a new
  model, out of usage). The line is encrypted with a key made from your pairing code, so only
  your friend can read it. It travels through [ntfy.sh](https://ntfy.sh), which sees neither the
  code nor the contents, or through your own ntfy server if you put
  `BRAINCELL_SERVER=https://…` in front of `install.sh`. Untick "Share what I'm working on" to
  leave the words out.
- **It installs** `~/.braincell`, a login item, and its hooks in `~/.claude/settings.json`, next
  to any you already have. Removing it takes all three out.
- **It costs** 0% CPU and about 12 MB of memory while hidden, under 1% of one core while the
  twins are out, and no tokens: the hooks print nothing.

## Remove

Click the twins and choose "Remove Braincell…", or run `~/.braincell/uninstall.sh`.

[MIT](LICENSE) licensed. Not affiliated with Anthropic.
