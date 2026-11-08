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
   (AGENT §7).
8. **No tracking; all UI text in the String Catalog; every control has an
   accessibility label.**

## Practical

- Run long checks in the foreground and report results; do not leave polling
  loops running in the background.
- Read every commit SHA from real command output; never guess one.
- Keep agent replies short (≤ 20 lines) unless asked; long output scrolls away.
