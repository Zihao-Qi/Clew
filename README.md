# Clew

A thread through your day. Clew is a macOS menu bar app that shows today's
list (one-off tasks, daily and weekly habits, and long goals like "10/30
videos") so that what's left, and what's done, is always one glance away.

Built for an ADHD brain: minimal text, visible progress, no streaks, no shame.

Status: v1a (menu bar list, once/habit/goal items, check-in and undo, Later pile).
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
