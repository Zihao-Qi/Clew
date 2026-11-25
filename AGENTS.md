# Working on Clew (for agents and humans)

Read [SPEC.md](SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and, for
anything AI-related, [docs/AGENT.md](docs/AGENT.md) before changing code.

## How work is done

- **One pull request per usable step.** Each step must leave the app usable on its
  own. Never push directly to `main`.
- **Builder and reviewer are different models.** One builds; a second one is briefed
  to *falsify* named claims, not to "review generally". Refuting a review comment
  is a fine outcome when the code supports it.
- **The user uses it the same day** a step lands. "Done" means used, not "tests
  pass" (SPEC: 5 of 7 days).

## Rules that are not negotiable

1. **Every new test must fail against a deliberately broken implementation**, and
   pass against the real one. Say in the PR how you confirmed this. A test that
   passes either way gets deleted.
2. **Green CI is not evidence of correctness.** Read the diff, and ask what each test
   would do if the code were wrong.
3. **Never change documented behaviour to make a test pass.** If the spec and the
   code disagree, stop and report; do not pick a side silently.
4. **Layering is enforced by SwiftPM targets.** Never add a dependency to
   `ClewDomain` (Foundation only) or `ClewCore`.
5. **Domain code never reads the clock or the time zone directly.** Inject them.
6. **Facts are never updated in substance or deleted.** Corrections are voids;
   the mutable fields and their merge rules are listed in ARCHITECTURE §4.2 / §8.
7. **The agent never changes user data.** Swift validates every agent output
   (AGENT §5).
8. **No tracking; all UI text in the String Catalog; every control has an
   accessibility label.**

## Practical

- Run long checks in the foreground and report results; do not leave polling
  loops running in the background.
- Read every commit SHA from real command output; never guess one.
- Before a commit, compare `git diff --stat` with the files you meant to change (a
  multi-file edit can fail halfway and leave a partial change).
- Before a PR: `python3 -I scripts/lint.py .` (also in CI); for app changes,
  `scripts/run-app-checks.sh` after a Debug build (also in CI); and the mutations for
  what changed: `python3 -I scripts/mutation-check.py . --changed` and
  `python3 -I scripts/mutation-check-app.py . --changed` (each picks the entries whose
  code line this branch changed; `--list` names them without running). Add entries for
  new rules first. A check you weakened or rewrote: also run its entries by name
  (`--only`). Run only the relevant tests locally (`swift test --filter`,
  `run-app-checks.sh --only`); CI runs everything (user, 2026-11-25).
- Run the app's checks only through `scripts/run-app-checks.sh` (`--only CLEW_NOTES_TEST`
  for one), never the Debug binary by hand: it refuses an app older than the sources,
  which is what a failed build leaves behind.
- Keep agent replies short (≤ 20 lines) unless asked; long output scrolls away.
