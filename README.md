# Clew

A thread through your day. Clew is a macOS menu bar app that shows today's
list (one-off tasks, daily and weekly habits, and long goals like "10/30
videos") so that what's left, and what's done, is always one glance away.

Built for an ADHD brain: minimal text, visible progress, no streaks, no shame.

Status: v1.2 (list, reminders and summaries, ratings, backups; YouTube Watch Later and
X bookmarks through a Chrome extension; focus timer; day timeline with time slots).
See [SPEC.md](SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [AGENTS.md](AGENTS.md).

## Install with Homebrew

```sh
brew tap zihao-qi/clew https://github.com/Zihao-Qi/Clew
brew install --cask clew          # later: brew upgrade --cask clew
```

Clew is signed with its own certificate but not notarized by Apple, so macOS blocks it
after each install or update: open **System Settings › Privacy & Security** and click
**Open Anyway** for Clew. Your data stays on that Mac (`brew uninstall --zap` is the only
thing that deletes it). macOS 14 or later.

**Releasing** (maintainer): bump `MARKETING_VERSION` in `project.yml` and `version` in
`Casks/clew.rb` in one pull request; after it is merged, push the tag `v<version>`. The
Release workflow builds, signs and publishes `Clew-<version>.zip`
(`scripts/release-build.sh` builds, signs and zips the same app locally, without publishing).

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
