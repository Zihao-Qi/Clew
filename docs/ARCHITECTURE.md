# Clew Architecture

Status: **proposal**, 2026-11-08. Companion to [SPEC.md](../SPEC.md). Decisions
marked **ADR-n** are recorded at the end with their alternatives.

## 1. What the architecture must survive

v1 is small: one menu bar list on one Mac. The plans around it are not, and
each one hardens into a constraint that is expensive to retrofit:

| Planned later | What it forces now |
|---|---|
| Public release, possibly the App Store | App Sandbox **on from day one**; no Accessibility; no spawning user binaries |
| Browser extension (YouTube Watch Later + watch %, X bookmarks) | Idempotent import keyed by external ID; a local API with auth |
| Opt-in AI coach (AGENT.md) | One command layer every client goes through; attribution of who changed what; agent kept out of user data |
| Daruma goals, levels, badges | History kept as facts, so rewards are derived and stable |
| Dayflow connection | A change feed that sync can resume from |
| iPhone + iCloud sync | UUID identity, tombstones, and an explicit merge policy per field |
| Obsidian / Markdown export | Read models separate from storage |

The guiding rule: **build only v1's features, but put v1's seams where these
plans will need them.** Every port below exists in v1; most have exactly one
implementation until their phase arrives.

## 2. Shape

```
            ┌──────────── Clew.app (single process, sandboxed) ─────────────┐
            │                                                               │
 user ────▶ │  MenuBar UI ─┐                                                │
            │  Notifications ─┤                                             │
            │  Settings ───┤      ┌────────────┐     ┌──────────────┐       │
            │              ├────▶ │ ClewCore   │ ──▶ │ ClewStore    │──▶ SQLite (WAL)
            │  Gateway ────┘      │ commands + │     │ GRDB, migr., │    + rolling backups
            │  (127.0.0.1, v1.1)  │ queries    │     │ change feed  │       │
            │       ▲             └─────┬──────┘     └──────────────┘       │
            │       │                   │ uses                              │
            │       │             ┌─────▼──────┐                            │
            │       │             │ ClewDomain │  pure Swift: no I/O,       │
            │       │             │ rules      │  no clock, no UIKit/AppKit │
            │       │             └────────────┘                            │
            └───────┼───────────────────────────────────────────────────────┘
                    │ HTTP + bearer token (localhost only)
     ┌──────────────┼───────────────────┬─────────────────────┐
 Chrome extension   clew-mcp (stdio)    Dayflow connector     CLI / scripts
 (YouTube, X)       ◀── Pi / Claude     (outbound, v2)
```

**One process owns the database. Everything else is a client of ClewCore**,
whether it is a button click, a notification action, the extension, or the AI
agent. That gives exactly one place where rules are enforced, one transaction
boundary, and one change feed. (ADR-1)

## 3. Modules

A Swift package with library targets and a thin app target. SwiftPM target
dependencies make the layering a **compile error** rather than a lint rule:

| Target | Depends on | Holds |
|---|---|---|
| `ClewDomain` | Foundation only | Entities, `LocalDay`, schedule evaluation, progress, achievement rules. Pure functions; `Clock` and `Calendar` are injected. |
| `ClewCore` | Domain | Use cases (commands + queries), validation, attribution, the `ClewStore` *protocol*, the `Notifier` *protocol*. |
| `ClewStore` | Core, GRDB | GRDB implementation: schema, migrations, change feed, backups, observation. |
| `ClewGateway` (v1.1) | Core | Local HTTP API `/v1`, auth, schema-versioned JSON. |
| `ClewApp` (app target) | all | SwiftUI `MenuBarExtra`, notifications adapter, settings, composition root. |
| `clew-mcp` (v1.2, executable) | none of the above | Thin stdio MCP server that calls the Gateway. |

An iPhone app later reuses Domain, Core and Store unchanged; only the UI target is new.

## 4. Data model

### 4.1 Definitions vs facts (ADR-2)

The core split: **what you intend** is mutable; **what happened** is append-only.

- **Definitions** (edited freely, soft-deleted): `Item`, `Reminder`, `Settings`.
- **Facts** (inserted, never updated in substance; corrected by voiding):
  `CheckIn`, `Plan`, `GoalRound`, `DayReflection` (v1.2), `Award` (v1.3). (`ItemProgress` is
  latest-state; see §4.2.)

Everything the UI shows (today's list, the `4/6`, progress bars, levels, recaps)
is **derived** from definitions + facts by pure Domain functions. This is not
full event sourcing: definitions are ordinary rows. It is the smallest split that
makes history trustworthy, rewards stable, and sync rules small and explicit (§8).

### 4.2 Entities

```
Item            id (UUID), kind, title, titleOrigin: typed | fetched, url?, note?, parentId?,
                schedule (JSON value type), progress (JSON value type),
                state: active | later | paused | archived,
                plannedDay?, sortKey, source, externalRef?,
                createdAt, updatedAt, deletedAt?
CheckIn         id, itemId, localDay, at (UTC), timeZoneId, amount (default 1),
                rating? (1–3), ratedAt?, source, voidedAt?, voidReason?
Plan            id, itemId, localDay, at, source, voidedAt?   ← "picked for today", kept as history
GoalRound       id, itemId, startedAt, localDay, target, source, voidedAt?   ← "next round" of a goal
Reminder        id, itemId, time (local), weekdays, enabled, updatedAt, deletedAt?
Settings        key (PK), value (JSON), updatedAt
— later phases —
ItemProgress    itemId (PK), fraction (0–1), observedAt, source   (v1.1) ← latest only, e.g. YouTube watch %
ChangeLog       seq (monotonic), entity, entityId, op, at, source  (v1.1) ← for Gateway "changes since" and sync
DayReflection   localDay (PK), valence (-1…1), bestItemId?, at, updatedAt  (v1.2)
Award           id = hash(kind, itemId, milestone), kind (e.g. goal.finished),
                itemId?, localDay, at, ruleVersion, voidedAt?  (v1.3)
```

- `kind` is `once | habit | goal | link`. SPEC's "Once / Repeating / Counted goal"
  map to `once | habit | goal`; `link` is a saved link (Later pile items).
  *Later pile* = items in state `later`. "Pick for today" sets `plannedDay` **and**
  records a `Plan` fact, so pick history survives later re-planning.
- **"Finished" is derived, not stored:** a goal is reached when
  `sum(amount of non-voided CheckIns since the current round started) >= target`;
  a once-item when it has a non-voided CheckIn. Undoing the last tick therefore
  un-finishes it, with no stored state to repair.
- **Goal rounds:** round 1 starts at creation and has no row. "Next round" inserts a
  `GoalRound`; the current round is the latest non-voided one, and check-ins before
  its `startedAt` belong to earlier rounds. Lifetime totals still count every
  check-in. A reached goal accepts no `+1` until a next round or a higher target.
- **`titleOrigin`:** `fetched` when the title came from the web page (stranger-written,
  untrusted for the agent, AGENT §4); editing the title makes it `typed`.
- **Composite progress:** `progress` is `.none`, `.counter(target)` (ML course
  10/30), or `.children` (**v1.1**, for imports: the "Watch later" row = done
  children / all children). A YouTube playlist imported as a course becomes a
  parent with 30 children, with no new concepts.
- `source` is `user | notification | extension.youtube | extension.x | dayflow |
  import`. Every write is attributed. **`agent` is never a source of user data**
  (ADR-4); agent writes exist only in `AgentOutput`.
- `(source, externalRef)` is unique, so imports are **idempotent upserts**:
  re-scanning Watch Later never duplicates.
- Undo is `voidedAt` on the fact, never `DELETE`.
- **Fields mutated after insert are named, with their merge policy** (see §8):
  `rating` (last writer wins by `ratedAt`), and `voidedAt`/`voidReason`
  (monotonic: once voided, stays voided).
- **Progress is latest-state, not a fact stream.** The extension may report watch %
  often; `ItemProgress` keeps only the newest value per item, so scans never bloat
  the database. Reaching 100% is the one transition that becomes a fact: a
  `CheckIn`, created only if the item has **no non-voided CheckIn from that source**,
  so re-scans cannot create it twice. (A deterministic ID was rejected: with
  monotonic voids, one accidental void would block that item forever.)

### 4.3 Time (ADR-3)

Dayflow's hardest bugs were day-boundary bugs. So the day is a **stored value
type, not something recomputed from timestamps later:**

- `LocalDay` = (year, month, day). It is computed **once**, when the fact is created, from
  the injected clock, the current time zone and the **day rollover hour**. It is stored
  on the fact together with `timeZoneId`.
- **Day rollover hour**: a setting, default **04:00** (decided 2026-11-08). Ticking
  something at 1 a.m. counts for the day you were still living in. Changing the
  setting affects only new facts; stored `LocalDay`s are never rewritten.
- Weeks start Monday (SPEC decision), using a **pinned ISO-8601 calendar** in Domain,
  never `Calendar.current`. In an en_US locale `Calendar.current` starts weeks on
  Sunday, which would silently move Sunday into the next week. "N× per week" is
  evaluated over the `LocalDay`s of facts, never over UTC ranges.
- `LocalDay(of: instant)` = the calendar date of `instant − rolloverHour`, computed
  with calendar arithmetic in the stored zone, so DST days stay correct.
- **Reminder times earlier than the rollover hour belong to the previous day.** A
  01:00 reminder on Monday's item fires at Tuesday 01:00 on the wall clock.
- Domain never calls `Date()`. Tests pin clock, zone, locale and DST transitions.

### 4.4 Schedules are values, evaluation is pure

```swift
enum Schedule: Codable { case daily, weekdays(Set<Weekday>),
                         timesPerWeek(Int), unscheduled }
func dueState(item: Item, on day: LocalDay, facts: [CheckIn]) -> DueState
//   .due, .doneToday, .satisfiedThisWeek, .notDue
```

The day an item is meant for lives in **one** place, `Item.plannedDay`. There is no
`.once(day)` schedule case, which would duplicate it.

**Today's list, precisely:**
- *once / link* with `plannedDay <= today` and no non-voided CheckIn → `.due`.
  "Quietly moves to tomorrow" is this rule; no background job rewrites anything.
- *habit* `daily` / `weekdays` → `.due` on matching days, `.doneToday` once ticked.
- *habit* `timesPerWeek(n)` → `.due` until it has check-ins on n distinct days this
  ISO week; then `.satisfiedThisWeek`. A week where n is no longer reachable still
  shows it as `.due`: doing one is fine, and "behind" is never shown.
- **Hidden from Today:** `.satisfiedThisWeek` items, unless ticked today.
- Items ticked today **stay visible until rollover**, so the rating row and undo
  work, and finishing a goal never makes it vanish under the pointer.
- The `done/total` title counts exactly the visible items.

Adding a schedule kind later (every N days, monthly) means one enum case plus a
property test. It needs no schema migration, because the schedule is stored as
versioned JSON.

## 5. Command layer (ClewCore)

Every mutation is a named command with input validation, one transaction, a
ChangeLog entry, and an attributed `source`:

`AddItem`, `EditItem`, `CheckIn`, `VoidCheckIn`, `Rate`, `PlanForToday`,
`MoveToLater`, `StartNextRound`, `DeleteItem` (tombstone), `ArchiveItem`,
`SetReminder`, `Export`; later
`ImportExternal(batch)`, `RecordProgress` (v1.1), `Reflect` (v1.2).

Queries are read models: `Today`, `Later(filter)`, `History(range)`,
`Goal(id)`, `Recap(range)`.

- **Idempotency:** commands accept an optional client `requestId`. A retried
  extension or agent call is a no-op. (Dayflow's `MutationReceipt` pattern, kept.)
- **Agent boundary (ADR-4):** the agent **never changes user data**. It has
  read-only queries, plus write access to its **own namespace** of `AgentOutput`
  records only: recaps, suggestions, link summaries. Applying a suggestion is
  a user action, which runs the normal command with `source = user`. The
  Gateway enforces this with token scopes (`read`, `agent-output`, `import`), not
  by convention.

## 6. Adapters

**Menu bar UI.** `MenuBarExtra` (window style). It observes the `Today` read model through
GRDB `ValueObservation`, so the list updates live when the extension or agent
writes. Every action is a command; the UI has no business logic.

**Title fetcher.** The app's only network use (entitlement
`com.apple.security.network.client`): when a link is pasted into `+ add`, one GET of
that URL with an ephemeral session (no cookies, no cache), `text/html` only, at most
3 MB, stopping at `</head>`. `PageTitle` (Core, pure) reads `og:title`, then
`twitter:title`, `<meta name="title">`, `<title>`. LinkPresentation was rejected: it
returns only the artist for YouTube music videos.

**Notifications.** This adapter is a **reconciler**, not a scheduler. It computes the
*desired* set of pending requests for a **rolling 7-day window** from reminders, due
state and summary settings. It diffs that against what is actually pending, and
adds, replaces or removes the difference. Requests use stable identifiers, so
replacing one is idempotent.
- **When it runs:** at launch, after every command, on the rollover-hour timer, on
  wake from sleep, and on clock or time-zone change. Timers can be late after sleep
  or App Nap, so wake and launch are what guarantee correctness; the window means
  tomorrow is already scheduled even if Clew does nothing overnight.
- **Summary text is fixed when a request is scheduled**, so future evening summaries
  are pre-scheduled with a **curated zero-tick line**. On a day's first tick, that
  day's request is replaced with "k/N done", and replaced again on each later
  change. A static "0/6 done" can therefore never fire. The morning "N today" is
  replaced whenever that day's list changes.
- Notification actions (Open / Done / Later) dispatch the same commands as the UI.

**Gateway (v1.1).** HTTP on `127.0.0.1` only, `/v1` JSON:
- **port:** a fixed preferred port, falling back through a small fixed range;
  clients find it by probing `GET /v1/hello` across that range;
- **pairing once:** Settings shows a 6-digit code; the extension or `clew-mcp`
  exchanges it for a scoped bearer token (`read`, `import`, `agent-output`) **and a
  per-install secret**. Tokens are stored in Keychain on Clew's side and are
  revocable per client;
- **the server proves itself before the client sends a token:** `hello` takes a
  client nonce and returns `HMAC(secret, nonce)`. A client that cannot verify it
  sends nothing. Without this, any local process squatting on the port could
  harvest the token;
- while the listener is active Clew holds a `ProcessInfo` activity assertion
  against App Nap (still to be measured in v1.1). The extension cannot launch Clew,
  so when Clew is unreachable it shows "Open Clew";
- `Host` header must be `127.0.0.1:<port>` (DNS-rebinding defence);
- `Origin` allowlist (the extension's ID), no wildcard CORS;
- request/response schemas live in one JSON Schema file. Swift types and the
  extension's TypeScript types are generated from it, with contract tests on both sides.
- Sandbox entitlement: `com.apple.security.network.server` (localhost).

**Browser extension (v1.1, separate TypeScript project).** Chrome MV3.
- **Scrapers are quarantined:** one module per site, with selectors in a single
  table. Tests run against saved HTML snapshots. Verified on 2026-11-08:
  `ytd-playlist-video-renderer` for Watch Later rows and
  `.ytThumbnailOverlayProgressBarHostWatchedProgressBarSegment` (style width %)
  for progress. The older resume-playback selector matched nothing.
- **Health report, not silence:** every scan posts `{found, parsed, selectorVersion}`.
  If a page that should have items parses zero, Clew shows "YouTube import needs
  an update" instead of importing nothing.
- Sends `ImportExternal` batches and `RecordProgress`. It does not compute
  progress itself.

**MCP server (v1.2).** `clew-mcp` is a tiny stdio executable. Its tools map 1:1 onto
Gateway endpoints and are **read-only** (`get_today`, `get_history`, `get_later`,
`recap_data`), plus writes into `AgentOutput` only (`post_suggestions`, under the
`agent-output` scope). It has no tool that changes user data (ADR-4). It holds no
logic, so Pi, Claude Code and anything else get identical behaviour. `clew-mcp` itself is not sandboxed, so if Clew is
not running it launches it in the background (`open -g -b <bundle id>`) and
retries once; only then does it report "Clew isn't running". Whether App Nap
delays a menu bar app's listener is **unverified** and must be measured in v1.1.

**AI agent (v1.2, ADR-5).** Designed in full in [AGENT.md](AGENT.md). In short:
`clew-agent` is a bundled helper built on Pi's lower two layers (`pi-agent-core`
+ `pi-ai`), compiled with Bun, **bundled in the app** (ADR-5), and spawned
per job by a Swift `AgentRuntime` over stdio. It has no database access: tools are
answered by Swift with read-only queries, and its JSON outputs are validated by
Swift before being stored as `AgentOutput`. Clew works fully with it absent.

**Dayflow connector (v2).** Outbound only, driven by `ChangeLog.seq` with a stored
cursor. It sends `X-Dayflow-Mutation-Id` so replays are safe. The mapping (CheckIn
→ Dayflow task completion vs. activity) is decided then, against Dayflow's
evidence-integrity rules.

## 7. Storage

- GRDB `DatabasePool`, WAL mode, file in the app container's Application Support.
- **Forward-only, versioned migrations** using GRDB `DatabaseMigrator`. Every
  release adds a fixture DB from the previous version, and a test migrates
  *every* historical fixture to head.
- **Rolling backups** with the SQLite online backup API: daily copies, keeping 14
  daily and 8 weekly.
- **Restore is staged, never live.** Swapping the file under an open `DatabasePool`
  (with its `-wal`/`-shm` files) risks corruption. So Restore writes a safety copy,
  stages the chosen backup, and relaunches. On launch, before the pool opens, a
  pending restore is applied and verified (`PRAGMA integrity_check`).
- **Export:** versioned JSON (`clewExportVersion: 1`) of definitions + facts,
  which is a complete and lossless round-trip. Markdown daily notes (Obsidian) are
  a separate read model.

## 8. Sync readiness (iPhone + iCloud, v2)

This needs no sync work in v1, but v1 must already follow these merge rules.
(The first draft claimed facts merge as a plain set union. Review showed that
was false, because some fact fields change after insert.)

| Data | Merge policy |
|---|---|
| CheckIn rows | union by `id`, which is then conflict-free |
| `CheckIn.rating` | last writer wins by `ratedAt` |
| `CheckIn.voidedAt` | monotonic: voided on any device means voided everywhere |
| Award | deterministic `id = hash(kind, itemId, milestone)`, so two devices earning the same milestone produce one row |
| Plan | union by `id`; void is monotonic |
| GoalRound | union by `id`; void is monotonic; the current round is the latest non-voided `startedAt` |
| DayReflection | one row per `localDay`; last writer wins by `updatedAt` |
| Item, Reminder, Settings | **row-level** last writer wins by `updatedAt` (every definition table has `updatedAt` + `deletedAt`). Field-level merge, if two devices editing different fields of one item ever matters, uses CKSyncEngine's server-record conflict callback with stored system fields; decided in v2 |
| `Award.voidedAt` | monotonic |
| ItemProgress | newest `observedAt` wins |
| Deletes | tombstones (`deletedAt`), never hard deletes |

Two devices ticking the same daily habit offline produce two CheckIns. That is
correct data, not a conflict: "done today" is a yes/no derived from ≥1 check-in,
and lifetime habit totals count **distinct days**. Counted goals sum `amount`, so a
double tick there is a real +2, which the user can void.

UUID primary keys are used throughout, never autoincrement IDs.

Target: CloudKit via `CKSyncEngine` (macOS 14 / iOS 17), mapping one record type
per table.

## 9. Derived rewards and reward themes (v1.3)

- Rules are pure functions over facts: `rules(facts) -> [AwardCandidate]`.
- When a candidate first appears it is **persisted as an `Award` fact** with
  `ruleVersion`. A later rule change never takes away a badge already earned.
- **But undo does:** if the CheckIn that triggered an award is voided (e.g. an
  accidental 30th tick), the award is voided with it, and re-earned on the real
  30th tick.
- **Awards are culture-neutral milestones; themes only change how they look.** Stored
  kinds are neutral (`goal.started`, `goal.halfway`, `goal.finished`,
  `total.milestone(n)`). A **RewardTheme** maps each kind to visuals and one
  short label. Switching theme re-skins every past award; no data changes.
- Theme catalogue (first is v1.3, others later): **Daruma** (Japan): first eye
  at start, second eye at finish. Candidates: stamp book (East Asian station
  stamps), laurel (Greco-Roman victory), constellation (a star lights up per
  milestone). Themes are data + assets, so adding one needs no schema change.
- Levels come from lifetime totals, never streaks (SPEC: no shame).

## 10. Quality

- **Dependency direction** is enforced by SwiftPM targets: Domain cannot import
  GRDB or SwiftUI, because it does not depend on them.
- **Domain:** unit tests plus property tests for schedules (random days ×
  random facts, e.g. "timesPerWeek(n) is never `.due` after n check-ins that
  week") and DST/time-zone fixtures.
- **Store:** migration-from-every-fixture test; backup → restore round-trip.
- **Gateway:** contract tests generated from the shared schema; auth/Host/Origin
  negative tests.
- **Extension:** HTML-snapshot scraper tests; a broken-selector test asserting
  the health report flags it.
- **Every new test must fail against a deliberately broken implementation**
  (AGENTS.md rule); a test that passes either way is deleted.
- CI: see §15 (Linux for Domain and Core, one macOS app build per pull request).

## 11. Deliberately not doing

- No server, account, or cloud in v1–v1.3.
- No full event sourcing, CQRS buses, or plugin system.
- No LLM calls from the app process. AI runs only in the optional `clew-agent`
  helper (AGENT.md); its credentials live in the Keychain.
- No Accessibility, CGEvent, or screen reading. If that is ever needed, it goes in a
  separate helper, never in the main app.
- No multi-process database writers (see ADR-1).

## 12. Phases

| Phase | Ships | New modules |
|---|---|---|
| v1a | Menu bar list, once/habit/goal, check-in + undo, Later pile (usable on day 1) | Domain, Core, Store, App |
| v1b | Reminders + summaries (reconciler), launch at login, JSON export | Notifications adapter |
| v1c | Ratings, "still want this?", rolling backups + staged restore | Backup service |
| v1.1 | Chrome extension: YouTube Watch Later + progress, X bookmarks | Gateway, extension |
| v1.2 | Evening question; AI daily coach, Later helper, daily dream; optional Reader | AgentRuntime, clew-agent, AgentOutput; clew-mcp |
| v1.3 | Daruma goals, levels | Award rules |
| v2 | Dayflow connector, iPhone + iCloud, Obsidian export | Sync, iOS UI |

## 13. Decisions

**ADR-1 Single-writer app process.** Every client (extension, MCP, CLI, Dayflow)
goes through ClewCore inside the app, via the Gateway.
*Alternative:* a helper opening the same SQLite file. That would work even when
the app is closed, but it would need shared App Group containers, multi-process
locking, and two copies of rule enforcement. *Revisit if:* clients routinely need
data while Clew is not running (it launches at login, so this should be rare).

**ADR-2 Mutable definitions, append-only facts.** *Alternatives:* plain CRUD
(simplest, but undo, sync, rewards and recaps all get harder); full event
sourcing (strongest, but heavy for a solo app). *Revisit if:* definitions need
history too, e.g. "show my goal as it was in March".

**ADR-3 Stored LocalDay with a rollover hour.** *Alternative:* derive the day from UTC
at read time. That is simpler, but wrong after time-zone changes and for 1 a.m. ticks.

**ADR-4 The agent never changes user data.** It reads, and writes only its own
`AgentOutput` namespace; the user applies anything it proposes. *Alternative:*
agent writes directly, which is faster but risks silent list churn that undermines
trust. Automatic ingestion (e.g. new Watch Later videos into Later) belongs to
the *import* path (extension, `import` scope), not the agent.

**ADR-5 Agent is a bundled helper on Pi's lower layers** (revised 2026-11-08).
`pi-ai` brings every provider and the ChatGPT login; `pi-agent-core` brings the
loop and a pre-tool-call hook. *Rejected:* (a) the user's own `pi` CLI via launchd
(first draft): fine for one power user, too heavy for the public, and the coding
layer is unwanted; (b) rewriting a provider layer in Swift: loses Pi's providers
and logins; (c) requiring Node: poor install experience. *Cost:* about 85 MB+ helper
(a compiled Bun hello-world measured 85 MB), accepted for now. *Revisit if:* the helper's size or the JIT entitlement blocks distribution.
Users who run Pi themselves can still connect through `clew-mcp`.
**Packaging (decided 2026-11-08):** the helper is **bundled and signed at build
time** inside `Contents/Helpers`, for everyone. Review showed that an "optional
download" into the signed bundle breaks the code signature, and that a downloaded
executable conflicts with App Store rule 2.5.2. *For the public release, revisit:*
a separate signed "Clew AI" companion app, so users without AI don't pay the size.

**ADR-6 Localhost HTTP for the extension.** *Alternative:* Chrome Native
Messaging, which needs a host manifest written into Chrome's own directory (awkward
from a sandbox, and Chrome-only). A Safari Web Extension bundled in the app
remains an option for an App Store build.

## 14. Open questions

1. Distribution: Mac App Store is possible but unlikely (2026-11-08). The sandbox
   stays on anyway as a no-regret choice; the store-vs-Developer-ID decision waits
   until public release.
2. Agent open questions are tracked in [AGENT.md](AGENT.md) §13.

## 15. Project-wide rules (decided 2026-11-08)

- **Bundle identifier:** `io.github.zihao-qi.clew`. It can change freely until Clew
  has real users; after that, a change needs a data migration, because the sandbox
  container, Keychain items and notification permission are keyed by it.
- **No tracking.** No analytics, no phoning home. Any future crash reporting is
  opt-in.
- **Localisation and accessibility from the first commit.** All UI text goes in a
  String Catalog (English first); every control has a VoiceOver label; the menu bar
  list is fully keyboard-navigable.
- **CI cost:** `ClewDomain` and `ClewCore` depend only on Foundation and are tested
  on Linux runners. One macOS job builds the app per pull request (macOS minutes
  cost 10× on private repos).
