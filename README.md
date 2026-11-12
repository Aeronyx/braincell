# Braincell

<p align="center">
  <img src="twins.gif" alt="The twins on a light and a dark menu bar" width="700">
</p>

Two little peekers in your Mac's menu bar who share one braincell. They pop up while you and a
friend are both working in Claude Code, act out what each Claude is doing, and nap when one of
you stops. For exactly two people (for now).

## Install

```bash
d=$(mktemp -d) && git clone --depth 1 https://github.com/Aeronyx/braincell "$d" && "$d/install.sh"; rm -rf "$d"
```

Needs macOS 13+, the Xcode Command Line Tools and Claude Code. It prints the line your friend
pastes, with your pairing code in it. Run it again to update, or with `new` after `install.sh`
for a fresh code. To meet the twins right away:

```bash
~/.braincell/Braincell --demo
```

## What they do

Yours is the solid one, your friend's the outline. Mostly they sit still and watch the
braincell. Now and then one acts out its Claude's work: gazing up to think, tapping its paws to
write, squinting at a command. Whoever stops nods off, and five minutes later they slip away.

Rarer things happen too: a hug after an hour apart, a high five for each hour worked together,
a slump when someone runs out of usage. (And some easter egg animations exist.)

Click them to read what each Claude is up to. Untick "Disappear when idle" there, and yours
stays out all day.

## Is it safe?

About 1,900 lines you can read in one sitting, compiled on your own Mac. No account, no
analytics, no admin rights.

- **Your prompts, code and commands never leave your Mac.**
- **Your friend gets one encrypted line:** busy or not, the kind of work, a mood, finished
  to-dos, and a few words from Claude's to-do list or command description (untick "Share what
  I'm working on" to leave the words out). [ntfy.sh](https://ntfy.sh) relays it and can't read
  it. For your own ntfy server, put `BRAINCELL_SERVER=https://…` right before `"$d/install.sh"`.
- **It costs** zero tokens, under 15 MB of memory, and 0% CPU while hidden (under 1% while
  they're out).

## Remove

Click the twins and choose "Remove Braincell…", or run `~/.braincell/uninstall.sh`. Either
takes out everything it added, its hooks in `~/.claude/settings.json` included.

[MIT](LICENSE) licensed. Not affiliated with Anthropic.
