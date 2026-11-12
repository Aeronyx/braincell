# Braincell

<p align="center">
  <img src="twins.gif" alt="The twins on a light and a dark menu bar" width="700">
</p>

Two little creatures that hang out at the bottom of your Mac menu bar and share one braincell; they only appear 
when both you and a friend are using Claude Code simultaneously, they act out what each Claude is doing, and 
they nap when one of you stops. Works for pairs only (for now). Incredibly lightweight and memory efficient.

## Quick Install (cleans itself up)

```bash
d=$(mktemp -d) && git clone --depth 1 https://github.com/Aeronyx/braincell "$d" && "$d/install.sh"; rm -rf "$d"
```

Required: Xcode Command Line Tools, macOS 13+, and Claude Code.
That command prints the exact line your friend should run, with your unique pairing code already in it. 
Run the same command again to update, or with `new` after `install.sh`to get a fresh pairing code. 
To see the twins without pairing, try:

```bash
~/.braincell/Braincell --demo
```

## What they (the twins) do

Mostly, they just hang out and pass around the braincell; sometimes, they act out their current
tasks: gazing up to think, tapping its hands to type, or squinting at a command. Whoever stops 
first goes to sleep, and five minutes later they disappear (by default).

Some rare things can happen too: a hug after an hour apart, a highfive for each hour spent working 
together, or a slump when one of you runs out of usage (plus some easter egg animations exist).

Click/hover them to read what each of your Claudes is up to. Untick "Disappear when idle"  and 
your creature always stays out, even when alone.

## Is it safe?

This is ~1,900 lines of Swift that you can easily read (or ask your Claude to read) in one sitting, 
compiled locally. No account, analytics, or admin rights; just two creatures who crave company.

- **All your prompts, code, and commands never leave your Mac.**
- **Your friend gets one encrypted line:** busy or not, the kind of work, a mood, finished
  to-dos, and a few words from Claude's to-do list or command description (untick "Share what
  I'm working on" to leave the words out). [ntfy.sh](https://ntfy.sh) relays it and can't read
  it. For your own ntfy server, put `BRAINCELL_SERVER=https://…` right before `"$d/install.sh"`.
- **Costs zero tokens, under 15 MB of memory**, and 0% CPU while hidden (under 1% while
  they're out).

## Uninstall

Click the twins and choose "Remove Braincell…", or run `~/.braincell/uninstall.sh`. Either
takes out everything it added, its hooks in `~/.claude/settings.json` included.

[MIT](LICENSE) licensed. Not affiliated with Anthropic.
