# Clew

A thread through your day. Clew is a macOS menu bar app that shows today's
list (one-off tasks, daily and weekly habits, and long goals like "10/30
videos") so that what's left, and what's done, is always one glance away.

Built for an ADHD brain: minimal text, visible progress, no streaks, no shame.

Status: v1c done (list, reminders and summaries, ratings, backups); v1.1 in progress
(Chrome extension: YouTube Watch Later into the Later pile).
See [SPEC.md](SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [AGENTS.md](AGENTS.md).

## Build and run

```sh
swift test                       # Domain, Core and Store tests (no app launch)
scripts/install-local.sh --launch   # Release build to ~/Applications, signed locally
```

`install-local.sh` creates a self-signed "Clew Local Development" identity once, so
rebuilds keep the same signature and the sandbox container. Needs XcodeGen
(`brew install xcodegen`). After changing UI text, run a build and then
`scripts/sync-strings.py <derived-data>` to update the String Catalog.

## Chrome extension (v1.1)

```sh
cd Extension && bun install && bun test && bun run build
```

Then in Chrome: `chrome://extensions` › turn on Developer mode › **Load unpacked** ›
pick `Extension/dist`. In Clew, open Settings › Browser › **Pair Chrome…** and type
the code into the extension's popup. Opening your Watch Later page imports it.
The extension talks only to Clew on `127.0.0.1` (ports 39271–39275); its fixed ID is
`jonldjbmjcdehoffcnkeobpapjkoebga` (from the manifest `key`), the only browser origin
Clew accepts. The wire format lives in [Contract/v1](Contract/v1/README.md).
