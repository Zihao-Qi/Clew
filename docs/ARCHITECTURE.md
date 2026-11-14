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
| `ClewGateway` (v1.1) | Core | Local HTTP API `/v1`, pairing and auth, the loopback listener (Network). Apple platforms only (CryptoKit). |
| `ClewApp` (app target) | all | SwiftUI `MenuBarExtra`, notifications adapter, settings, composition root. |
| `clew-mcp` (v1.2, executable) | none of the above | Thin stdio MCP server that calls the Gateway. |

An iPhone app later reuses Domain, Core and Store unchanged; only the UI target is new.

## 4. Data model

### 4.1 Definitions vs facts (ADR-2)

The core split: **what you intend** is mutable; **what happened** is append-only.

- **Definitions** (edited freely, soft-deleted): `Item`, `Reminder`, `Settings`,
  `TimeBlock` (v1.2).
- **Facts** (inserted, never updated in substance; corrected by voiding):
  `CheckIn`, `Plan`, `GoalRound`, `LaterReview`, `DayReflection` (v1.2), `Award` (v1.3). (`WatchProgress` is
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
LaterReview     id, itemId, decision: keep | letGo, at, localDay, source, voidedAt?   ← "still want this?"
Reminder        id, itemId, time (hour, minute; local), enabled, updatedAt, deletedAt?
                ← at most one live reminder per item; it fires on the item's due days
Settings        key (PK), value (JSON), updatedAt
— later phases —
WatchProgress   itemId (PK), fraction (0–1), observedAt, source   (v1.1) ← latest only, YouTube watch %
FocusSession    id, itemId, localDay, at, minutes (1–720), kind: timer | manual, voidedAt?   (v1.2) ← a fact
TimeBlock       id, itemId, localDay, start, minutes, placedAt, updatedAt, decidedAt?, tickId?,
                coverId?, removedAt?   (v1.2) ← a definition: the day timeline (§6)
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
  import | timeline` (a time block's own tick, v1.2). Every write is attributed. **`agent` is never a source of user data**
  (ADR-4); agent writes exist only in `AgentOutput`.
- `(source, externalRef)` is unique, so imports are **idempotent upserts**:
  re-scanning Watch Later never duplicates.
- Undo is `voidedAt` on the fact, never `DELETE`.
- **Fields mutated after insert are named, with their merge policy** (see §8):
  `rating` (last writer wins by `ratedAt`), and `voidedAt`/`voidReason`
  (monotonic: once voided, stays voided).
- **Watch progress is latest-state, not a fact stream.** It arrives with each
  Watch Later scan (`ExternalEntry.progress`, 0–1, rounded to 0.01; out of range is
  ignored, the video still imported). `WatchProgress` keeps one row per item, the
  newest `observedAt` wins, and an unchanged reading writes nothing, so re-scans
  never bloat the database. Progress itself never creates a `CheckIn` (*changed from
  the plan*, user decision 2026-11-09: progress is shown, not acted on); the only
  automatic tick is the one a video gets when it leaves Watch Later (*changed*
  2026-11-10, "removed means finished", see Import rules), whatever its progress. A video the user deleted gets no progress. It is named
  `WatchProgress`, not `ItemProgress`, to keep it apart from `Item.progress`.

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
`ImportExternal(batch)` (also carries watch progress, v1.1), `Reflect` (v1.2).

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
writes. Every action is a command; the UI has no business logic. A global shortcut
(default ⌘., stored in Settings as `openListShortcut`) opens the list by clicking
Clew's own status item; Carbon registers the hotkey, so no Accessibility permission
is required (2026-11-11).
**Collection peek (2026-11-13; Fable review).** The panel lists
`CollectionDetails.inProgress + notStarted` (it reads `model.collections` like the page,
so it re-renders on changes). **Core** holds the pure parts, tested with injected time:
`PeekState` (events: pointer moved on/off a row with its **screen** position
(`onContinuousHover(coordinateSpace: .global)`, so a row sliding under a still pointer
is not movement: "moved" needs two different positions), entered/left the panel, tick,
row clicked, drag began, list left (the list view's `onDisappear`: ⌘N, ⌘L, details;
it also clears the click block), menu closed, list emptied → open/closed for which
source; open after 0.1 s of rest that began with movement (arriving on a row at a new
position is movement; the row under the pointer is found by the controller from the
rows' screen frames (their bounds: SwiftUI does not clip hosted views, so `visibleRect` is the whole window) on each hover event, since SwiftUI's `onHover` for a row can come
after the list's hover event); while closing, the 0.2 s
restarts as long as the pointer moves toward the panel's side; another row takes over
only after its own rest, and time heading for the open panel is not rest; no reopen
after a click until the row is left) and
`peekFrame` (280 pt wide, flush with the menu window, left if the screen's visible
frame has room else right, top at the row, moved up to fit). **App:** a borderless
`NSPanel` (`.nonactivatingPanel`, `canBecomeKey`/`canBecomeMain` false, clear
background, `hasShadow`; on macOS 26 SwiftUI's `.glassEffect(.regular)` in a 12 pt
rounded rectangle, the glass the `MenuBarExtra` window draws (`CABackdropLayer` with
`glassBackground`), else `.regularMaterial`), attached with `addChildWindow(_:ordered:
.above)` to the menu's window; every close does `removeChildWindow` and `orderOut` (a
child ordered out with its parent would come back with it). Its `NSHostingView`
subclass accepts the first mouse, and a title opens on **mouse-down** (whether the
menu window closes on a click in another window of the app is private; opening on
the press works either way). Hover in the panel comes from an `NSTrackingArea`
(`.activeAlways`, `.mouseEnteredAndExited`, `.mouseMoved`), not SwiftUI's `onHover`
(unverified in a never-key window). The list reports row hover with positions
(`onContinuousHover`), clicks and drags; the menu window's `didResignKey`/`willClose`
close it and cancel any pending open, one main-queue turn later (as the name box's
watcher does), so the panel's own mouse-down is handled first. A title is pressed, not
a SwiftUI `Button`, so it carries `.isButton`, the label "Open <title>" and a default
accessibility action that opens it.

**Title fetcher.** The app's only network use (entitlement
`com.apple.security.network.client`): when a link is pasted into `+ add`, one load of
that URL (following http(s) redirects) with an ephemeral session (no cookies, no cache), `text/html` only, at most
3 MB, stopping once a complete `<meta property="og:title">` has been read (checked every
256 KB; `</head>` is no signal:
YouTube playlist pages contain one inside a script before their title). `PageTitle` (Core, pure) reads `og:title`, then
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
- Notification actions (Open / Done / Later) dispatch the same commands as the UI,
  with `source = notification`.
- **Split (v1b):** `NotificationPlanner` (Core, pure, Linux-tested) plans the window
  and diffs id → fingerprint maps; the app adapter only renders localized text,
  reads what is pending and applies the difference, touching only `clew.` ids.
  At most 64 requests are kept (the system's per-app limit), earliest first. The
  curated zero-tick lines live in the app's String Catalog.
- **Permission** is asked the first time a summary or reminder is switched on, never
  at launch. If it is off in System Settings, Settings and the reminder row say so.

**Gateway (v1.1, `ClewGateway`; built 2026-11-09).** HTTP/1.1 on `127.0.0.1` only,
`/v1` JSON, one request per connection:
- **port:** the first free port of **39271–39275**; clients probe `GET /v1/hello`
  across that range, trying the last port that answered first;
- **pairing once:** Settings › Browser shows a 6-digit code, valid 5 minutes and 5
  tries, single use. `POST /v1/pair` exchanges it for a client id, a scoped bearer
  token and a per-client secret. The extension gets the `import` scope only (`read`
  and `agent-output` arrive with their endpoints). Clew keeps the clients **in the
  login Keychain** (one item; tokens only as SHA-256 hashes), never in the database,
  so exports and backups never carry them. Settings lists paired browsers with Remove;
- **the server proves itself before the client sends a token:** `hello` takes a
  client nonce (and the client id) and returns `HMAC-SHA256(secret, nonce)`. A
  client that cannot verify it sends nothing; an answer without a proof means "Clew
  no longer knows this browser" (pair again). The client never follows redirects
  (`redirect: "error"`), so a squatter cannot bounce `hello` to the real Clew and
  then receive the token on its own port. Pairing itself has no proof: it is a
  one-time, user-attended step;
- **the listener runs only while a browser is paired or a code is shown**, and while
  it runs Clew holds a `ProcessInfo` activity (`userInitiatedAllowingIdleSystemSleep`)
  against App Nap. Whether App Nap would delay replies without it is still
  unmeasured. The extension cannot launch Clew, so when Clew is unreachable it says
  "Open Clew";
- `Host` must be exactly `127.0.0.1:<port>` (DNS-rebinding defence; `localhost` is
  refused); an `Origin`, if present, must be the extension's fixed ID
  (`chrome-extension://jonldjbmjcdehoffcnkeobpapjkoebga`, from the manifest `key`);
  no wildcard CORS. Bodies up to 4 MB, `Content-Length` only, JSON only;
- while a restore swaps the database, imports get `503` and the client retries on
  its next scan; the swap first waits for an import already running to finish;
- **contract:** example requests and responses live in `Contract/v1/*.json`. Swift
  tests decode and re-encode each one unchanged and check that the import example's
  response is the Gateway's real answer; the extension's tests run its validators
  and request builders against the same files, and both sides check one fixed HMAC
  vector. *Changed from the plan* (JSON Schema plus generated types): a code
  generator was more machinery than six small messages need; revisit if the API grows.
- Sandbox entitlement: `com.apple.security.network.server`.

**Import rules (`ImportExternal`, Core).** Idempotent by `(source, externalRef)`.
The URL is built from the id (YouTube: exactly 11 of `A–Z a–z 0–9 _ -`), never taken
from the client; titles are cleaned, cut to 200 characters and stored as `fetched`
(untrusted). A title the user edited is never overwritten. A scan counts as the
**whole list** only when the page's own count, the rows on the page and the entries
read all agree, no entry was malformed, and the list is not empty (a "No videos" page
also shows when signed out or broken, so an empty read is never trusted: emptying
Watch Later entirely leaves the collection as it is). Only then are items from that
source that left the list let go, ticked or not (*changed* 2026-11-09 with
collections; before, items on Today or ticked were never touched) (a `LaterReview` with the import's
source, so Settings' "let go" count, which counts the user's own, skips it). **Removed
means finished** (SPEC 2026-11-10): in the same transaction, each one without a live
check-in gets one (`amount` 1, the import's `source`, today's `localDay`); one already
ticked is not ticked again. An item let go that way comes back if it reappears: its
let-go is voided, and so are the ticks the import gave it (source = the import's), so
it is to watch again; a tick the user made stays. Anything the user deleted stays gone
for scans; only an X bookmark click brings a deleted post back (see the state table). A source
turned off (`collectionsOff`, setting `collectionsOff`: a JSON array of source raw
values; unknown ones are dropped) refuses the import with `ClewError.listTurnedOff`
before anything is read or written; the Gateway answers 409 and the extension shows
"turned off in Clew".

**X bookmarks (SPEC 2026-11-10).** `extension.x` refs are post ids (1–19 digits, no
leading zero, within `Int64`); the URL is `https://x.com/i/status/<id>`. X is an
*ordered source*: its scans are `complete` only when the extension saw the list's end
(never from a stray `listTotal`). Removals come from:
- **The end of the list** (2026-11-13), `ImportBatch.reachedEnd` (API
  `ImportRequest.reachedEnd`, optional: older extensions omit it, older Clews ignore it).
  The batch is the whole list when `reachedEnd`, the scan report agrees, nothing was
  skipped, the entries are not empty and `fromTop == entries.count` (one unbroken run
  from the top). Then every live item not in it leaves (`leaveList`), except items
  whose `updatedAt` is within `restoreAfter` (10 minutes: bookmarked, brought back or
  renamed, so the page may predate it); the order becomes those kept items, then the
  entries. **Cap:** if more than 20 would leave and that is more than half the live
  items, nothing leaves by this rule (the gap rule runs as before). The extension sets
  `reachedEnd` only when the scan's run is unbroken, every row above the last held a
  readable post, the last row (by `translateY`) holds no post, no text and no button,
  is inside the viewport, no `[role="progressbar"]` is on the page, the row count and
  entries stayed the same for 3 seconds (re-checked on scroll and when sending), and
  the visit began less than 10 minutes ago. Checked on the signed-in page
  2026-11-13 (4 bookmarks): the last row is an empty `cellInnerDiv` 200 points tall,
  and nothing loads after scrolling to it; a long list's last row before more load is
  not verified, which is why it must stay still on screen.
- **The gap rule**, on `ImportBatch.fromTop`, the leading entries the extension saw as
  one unbroken run from the top. Only when the scan report agrees and nothing was
  skipped (else the run is 0); a negative run is 0. `gapRule(previous:top:)` takes the
  order Clew last saw (live items only) and the run. A post bookmarked again on the
  phone (unseen) jumps to the top, so the list is a block of moved posts above the
  rest in its old order. Only the part of the run *after its last step backwards* in
  the old order is trusted (Gemini review 2026-11-10: pairs inside the moved block
  prove nothing). For each pair of consecutive known posts there, every post between
  them in the old order that is not in the run was removed. With nothing out of order,
  the top of the list is a bound too, so the newest bookmark removed on the phone is
  caught. Once the run reaches the
  posts that never moved, every gap is real; a run lying wholly inside a moved block
  of two or more posts is the remaining blind spot ("Not read" undoes it). The new
  order is the run, then the rest as before. It is kept in the setting
  `listOrder.extension.x` (a JSON array of refs; derived state, rewritten only when it
  changes).
- **The bookmark button**, `bookmarkChanged(source:entry:bookmarked:)` (Gateway
  `POST /v1/bookmark`): bookmarked adds the post at the top of the order, restores it
  if it had left (to read again), or brings it back if the user had deleted it (ticks
  voided); posts no longer live are dropped from the order;
  unbookmarked makes a live post leave the list
  like any removal (`leaveList`: tick unless ticked, the import's let-go). Unknown
  posts are ignored when unbookmarked; a bookmark needs a title.
Both refuse a list turned off (`listTurnedOff`, 409).

**Collection item states (2026-11-10).** Every rule above is one cell of this table,
so no two of them can disagree. States: **to do** (on the list, not ticked), **done
on list** (ticked, still on the list), **left** (the import's let-go is the latest;
ticked, so in Done), **not read** (left, ticks voided by "Not finished/Not read":
hidden), **deleted** (deleted by the user: hidden, its ticks out of the heatmap and
counts).

| Event ↓ / state → | to do | done on list | left | not read | deleted |
|---|---|---|---|---|---|
| Scan sees it | — | — | to do*, keeps a user tick; only if it left ≥ 10 min ago | to do, same wait | stays deleted |
| Scan says it is gone (whole list / gap rule) | left + tick | left (no 2nd tick) | — | — | — |
| Bookmark click (X) | to top | to top | to do*, at once | to do, at once | to do, ticks voided |
| Unbookmark click (X) | left + tick | left | — | — | — |
| Tick / undo today | done on list | undo today only | — | — | — |
| Not finished / Not read | — | — | not read | — | — |
| Delete | deleted | deleted | — | — | — |
| List turned off | everything refused; nothing changes | | | | |

\* "to do" unless the user had ticked it themselves: then done on list. Auto ticks
(source = the import's) are voided on the way back; the user's never are. The
10-minute wait (`Clew.restoreAfter`) is what keeps a stale scan, such as another tab
still showing the post or rows read just before a click, from undoing a removal; a
click is never stale.

**Focus timer (v1.2, SPEC 2026-11-10).** Not a fact: the one running timer,
`FocusTimer {phase: focus | rest, itemId, startedAt, length, pausedAt?, pausedFor}`, is
kept in the setting `focusTimer` (JSON; `null` when none; an unreadable one is no
timer), so it survives sleep and quitting. All times are absolute; elapsed time never
goes below zero if the clock moves back. Commands: `startFocus(itemId:minutes:)`
(only `focusMinutes` = 10/25/45, only items on today's list, which never holds a
collection's items; a running focus throws `focusRunning`, a break is replaced),
`pauseFocus`, `resumeFocus` (adds the paused span), `extendFocus` (focus only: +5 min
from now, or from the planned end if not up yet), `startBreak` (only from a focus whose
time is up, only when breaks are offered), `finishFocus` ("Done/+1": the tick the
circle would make but never an undo, since `checkIn` keeps a day's existing tick; no
+1 past a goal's target; then the timer ends), `stopFocus` (returns what ran). The end is a planned notification (`clew.focus`, first in the plan
so the 64-pending cap never drops it), absent while paused, once over, or when its
task is no longer active (moved to Later). The app ends
a timer whose task left Today and a break that is over, and refreshes at `endsAt`.

`stopFocus`, `finishFocus` and `startBreak` save the focus that ended as a
`FocusSession` (kind `timer`: real minutes rounded, pauses left out, at least 1; `at`
and `localDay` from its start; never a break; nothing if the task was deleted, since
its details are gone) when the setting `focusRecordsTime` is on (default). `addFocusTime(itemId:day:minutes:)` adds a `manual` one (1–720 minutes, a day
up to today, a live task, not a collection item; allowed with recording off; the app's
picker stops at Clew's today, which before the 4 a.m. rollover is still yesterday).
`removeFocusSession(id:)` voids one (twice changes nothing). `focusSummary(itemId:)`:
minutes this week and in all (days up to today, voided left out) and the latest
sessions, newest day first. The table has the fact triggers (no delete, substance
immutable, monotonic void) and `minutes BETWEEN 1 AND 720`; exports carry it (older
exports read as none). The app
only redraws the timed row and the menu bar label every second, from the model's
one-second tick (`clockTick`, running only while a timer exists). Never a
`TimelineView` in the menu bar label: SwiftUI then redraws the status item without
end (measured 2026-11-10: 99% CPU in a minimal MenuBarExtra, 0.1–2% with the tick).

**Day timeline (v1.2, SPEC 2026-11-10).** A placed task is a `TimeBlock`, a
**definition** (it moves and resizes), tombstoned with `removedAt`, never deleted:
`TimeBlock {id, itemId, localDay, start, minutes, placedAt, updatedAt, decidedAt?,
tickId?, coverId?, removedAt?}`. `start` is an instant on a 15-minute step counted from
the day's start (the rollover instant, so DST days stay right); `minutes` is a multiple
of 15, at least 15, and the block ends by the next rollover. A block's own tick is a
normal `CheckIn` with `source = timeline` and `localDay` = the block's day (the one
exception to "the day comes from the clock at creation", §4.3); its `at` is when it was
made, so a goal's rounds and "ticked while a focus ran" compare real instants.
`tickId` points at it; `coverId` at the hand tick the block used instead. "Hand" ticks
are every source but `timeline`.

- **Deciding** (`settleBlocks`, Core): a live block whose end has passed and has no
  `decidedAt` decides once, then keeps `decidedAt`. Its task must be live and active
  (else the block is removed and never ticks). It **skips** when the task needs
  nothing: a once-task or link done (on any day), a habit ticked on the block's day, a
  goal reached in its current round. A goal is **covered** by the earliest live hand
  tick on the block's day made at or after `placedAt` that no other block (removed ones
  included) uses; it is kept in `coverId`, so after a move the same tick covers it again
  and another block cannot take it. Otherwise it **ticks**. States are derived:
  `pending` (no `decidedAt`), `ticked` (`tickId` live), `undone` (`tickId` voided),
  `covered` / `skipped` (decided, no `tickId`).
- **Commands:** `placeOnTimeline(itemId:start:minutes?)` (the row's drag and "Put on
  timeline…": moves the task's earliest block not ended, else adds one; 30 minutes by
  default, and a moved block's length, cut at the day's end; only rows on today's list), `moveBlock(id:start:)`,
  `resizeBlock(id:minutes:)`, `addBlock(after:)` (same length, right after; refused if it
  would pass the day's end), `removeBlock(id:)`, `blockNotFinished(id:)`,
  `addOnTimeline(title:titleOrigin:url:start:)` (2026-11-13, the timeline's double-click:
  in **one write**, the today task `addItem(.today)` would make and a 30-minute block at
  `start`, cut at the day's end, deciding at once if it has ended; a `start` outside
  today, e.g. after a rollover, refuses the whole command and makes nothing; the clock is
  read once, for the task's `plannedDay` and the block's day). Moving or
  resizing changes the end, so it voids a live `tickId`, clears `decidedAt`/`tickId`
  (keeps `coverId`) and decides at once if the new end has passed. Removing voids a live
  `tickId`. **Rounds:** a `tickId` made before the goal's current round started is
  kept: move and Not finished are refused (`notAllowed`), remove keeps it. Every command
  works on today's blocks only.
- **Leaving Today:** `settleBlocks` first removes today's live blocks whose task is not on
  today's list (any reason; the rollover never runs this on an earlier day's blocks),
  then decides. It writes only when something changes, so the app can run it on every
  refresh (launch, wake, every change, the next block's end) without a loop.
- **Earlier days:** `lateTicks()` = live block ticks with `localDay` before today and
  made today (`LocalDay(of: at)` = today), grouped by task, minus the ids in the setting
  `lateTicksSeen` (dismissed). Their Not finished voids all of a task's listed ticks,
  unless the rounds rule keeps one. A goal whose current round was reached that way
  stays on Today's list (`todayList(keepReached:)`), so its congratulation shows.
- **Focus:** `finishFocus` makes no tick when a live block tick of the same task was
  made between the timer's `startedAt` and now.
- **Alerts:** the plan adds `clew.block.<id>` at each of today's pending blocks' start
  (after now), for a task that still needs something, when the setting `blockAlerts`
  is on (default). `wantsNotifications` counts it; the app asks permission when the
  first block is placed (by a drop, Put on timeline… or `addOnTimeline`).
- **Display** (`timeline()`): the day's start and end, and today's live blocks of
  tasks on the list with title, state, `canChange` (the rounds rule) and a lane, so
  overlapping blocks sit side by side (the double-click's open name box joins that layout
  as a draft block while it is open, so neighbours make room at once and nothing moves on
  Return). `placedItems` = tasks with a live block today:
  while the timeline shows, the app leaves them out of the list's rows (they still
  count in `done/total`, which Core computes from the whole list). The setting
  `timelineShown` (default on) hides the timeline and puts every task back in the list. The table `timeBlock` (v8) has no-delete; exports carry it (older read as none).

**Time slots (v1.2, SPEC 2026-11-10).** `Item.slot: TimeSlot? {hour, minute, minutes}`
(a definition field, JSON column `slot`, migration v9; habits and goals only; `ItemEdit.slot`
is `.keep` or `.set(slot?)` so older edit paths never clear it). `TimeBlock` gains
`origin: hand | slot`, `touchedAt` (moved, resized or removed by hand: today's own),
`askedAt` (a slot block asking "Done?") and `releasedAt` (a goal that reached its total
went back to the list); exports from before read `origin` as `hand`.
- **settleBlocks, in order:** earlier days' blocks decide (a slot block's question ends:
  `decidedAt`, no tick); today's blocks whose task left the list are removed, and those
  of a goal now reached are released; today's blocks whose end passed decide; then, while
  the timeline shows, slot blocks are placed (`placeSlotBlocks`): a task with a slot, on
  the list, needing something, with no block today (removed ones count), whose slot
  starts after now.
- **A slot block never ticks.** `decide` computes one outcome (skip / cover / tick); a
  slot block turns *tick* into asking (`askedAt`, only while the timeline shows) and is
  answered when a later evaluation gives skip or cover (any hand tick). Asking blocks
  stay pending (`decidedAt` nil), and asking again writes nothing.
- **Edit** (`slotChanged`, inside the edit's write) moves today's slot block only if
  untouched and not started, else removes it when the new slot has started or the slot
  is off. Hand changes set `touchedAt` and clear `askedAt` and `releasedAt`.
- **Wall clock:** `slotPlacement` takes `LocalDay.instant(at:)`; a time a DST change
  skipped moves to the end of the gap; cut at the day's end.
- **Notifications:** `clew.ask.<blockId>` at a waiting slot block's end ("Done with …?",
  Done or +1), under `blockAlerts` and only while the timeline shows. Its action answers by
  block (`answerSlotBlock`), never for an earlier day; the app removes delivered
  questions for blocks no longer asking (`askingBlockIds`).
- `placedItems` leaves out released blocks; placing a reached goal is refused; a hand
  move un-releases.

**Calendar events (v1.2, step 2).** Read live through EventKit in the app
(`EventKitCalendar`, behind `CalendarReading` so the snapshot uses made-up events), never
stored: no table, no export. Full access is requested only from "Show your calendar"
(macOS 14 has no read-only access; `NSCalendarsFullAccessUsageDescription` says Clew only
reads); the sandbox entitlement is `com.apple.security.personal-information.calendars`.
Declined invitations are skipped by the adapter; `EKEventStoreChanged` refreshes. Core's
`Clew.timelineEvents(_:day:hidden:)` (pure, tested) drops hidden calendars and events
outside Clew's day, keeps all-day ones apart, cuts timed ones to the day, and lays out
blocks and events together (`blockPlaces`, `eventPlaces`; `timelineLayout`, which also places
the double-click's open name box as a draft block, 2026-11-13). Settings: `calendarShown`
(default off), `calendarPromptClosed`, `calendarsHidden` (only unticked ids, so new
calendars show).

**Site order (2026-11-10).** Every collection keeps the order its site shows in the
setting `listOrder.<source>`, and its page lists what is left in that order (items
not placed yet last, newest first). X's comes from the gap rule, the list's end and the button.
Watch Later's is rewritten by each scan: the live items it saw, in page order, then
the live items it did not see, as before (so a partial scan moves nothing it did not
see). The extension drops a post from the visit's scan when it is unbookmarked there,
and never counts a row that shows the "Bookmark" button: before, a scan sent after
the click brought the post straight back (seen 19 → 18 → 19).

**Collections (v1.1, SPEC 2026-11-09).** Items whose source is in
`Clew.collectionSources` (YouTube, then X) form one collection per source. There
is no parent row: a collection is derived from `source`, so nothing needs migrating.
Today, Later, Pick, reordering and notifications all filter collection items out
(including ones picked before collections existed); `PlanForToday` refuses them;
`CheckIn` accepts them in any state, since they are ticked on the collection's page.
Queries: `collections()` (the rows below the tasks, for sources turned on:
`toWatch`, live and unticked; `done`, the Done group; `onList`; a source with no
items left keeps its row while it has any tick) and `collection(source)` (the page:
groups, and ticks per day including items since removed). The Done group is ticked
items that are live or **left the list** (removed, and the import's let-go is their
latest). Items the user deleted are not in it, and their ticks are out of the heatmap
and counts too (*changed* 2026-11-10, user: a deleted article still coloured the
heatmap while Done said 0); the facts themselves stay. `markNotFinished(itemId:)` voids every live tick of an item that left the
list (reason "not finished"), taking it out of Done and the heatmap; it refuses items
still on the list, ones the user deleted, and tasks. Done-ness uses every live tick, like the row and `CheckIn`, even one dated
after today (clock or time zone moved back); the heatmap and counts show days up to
today only. The Gateway's import answer reports `listCount`, the items on the list
(`onList`; *changed from* `laterCount`).

**Browser extension (v1.1, `Extension/`, TypeScript, built with Bun).** Chrome MV3.
- **Scrapers are quarantined:** one module per site (`src/youtube.ts`, `src/x.ts`), with selectors
  in a single table and a `SELECTOR_VERSION`. Tests run against saved HTML snapshots.
  Verified on 2026-11-08: `ytd-playlist-video-renderer` for Watch Later rows and
  `.ytThumbnailOverlayProgressBarHostWatchedProgressBarSegment` (style width %)
  for progress. The older resume-playback selector matched nothing. The list's own
  count ("12 videos", "No videos") is read from the playlist header (byline and
  sidebar, both seen on the real page 2026-11-09; no broader fallback); a count in
  another language is not read, so nothing is ever removed then.
- **Health report, not silence:** every scan posts `{found, parsed, selectorVersion}`.
  If rows are found but not all read, an entry is rejected, or the page's count says
  it has items while none were read, Clew shows "YouTube import needs an update"
  (list footer and Settings) and removes nothing.
- The content script scans when the Watch Later page opens (YouTube is a single-page
  app: `yt-navigate-finish`) and again as more rows load; the service worker is the
  only part that talks to Clew, and skips an identical scan within a minute.
- Sends `ImportExternal` batches, each video with its watch progress when its
  thumbnail shows the red bar (verified 2026-11-09 on the Watch Later page:
  `ytw-thumbnail-overlay-resume-playback-renderer` > a div with `style="width: N%"`;
  the 2026-11-08 class is kept as a fallback). Progress is read only from the
  Watch Later page, not while a video plays (user decision 2026-11-09: no second
  scraper on the player). It does not compute anything else.
- **X (`src/x.ts`, `src/content-x.ts`, on x.com only).** X keeps only the rows near
  the screen, so `BookmarkScan` builds one scan from what it sees while you scroll
  (rows sorted by their `translateY`). The run from the top starts only if the first
  row seen is at `translateY(0px)`, and ends at the first look with no post in common
  with what was seen (the page jumped); later rows are added, not compared. A row it
  cannot read raises `found` above `parsed`, so Clew compares nothing. Looks are
  throttled to every 250 ms and the scan is sent 1.5 s after the page settles. A
  capture-phase click listener on `document` sees the bookmark button before X flips
  it (`bookmark` = being bookmarked, `removeBookmark` = being removed) and posts to
  `/v1/bookmark` at once. Checked on the signed-in page 2026-11-10: Bookmarks lives
  at `/i/history` (its Bookmarks tab; `/i/history/likes` is Likes and is ignored;
  `/i/bookmarks` still accepted); rows are `cellInnerDiv` with `translateY` (fractions
  too); the button is `<button data-testid="bookmark|removeBookmark">`; quotes are in
  `div[role="link"]` with their own time link. An X Article has no `tweetText`: its
  title is the first `[dir="auto"]` text in the card around `article-cover-image`
  (never the author's name, never a quoted article's), and it is preferred to the
  post's own text.

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
  daily and, from older ones, the newest of each of 8 weeks (22 at most;
  `BackupRetention`, pure). Each copy is switched to a single-file journal and
  LZFSE-compressed (about 4× smaller), in `Backups/` beside the database.
- **Restore is staged, never live.** Swapping the file under an open `DatabasePool`
  (with its `-wal`/`-shm` files) risks corruption. So Restore writes a safety copy,
  stages the chosen backup and verifies it (`PRAGMA integrity_check` and Clew's
  tables), then **closes the pool**, swaps the file and reopens, inside the running
  app (v1c: same guarantee as a relaunch, without one). `SQLiteStore.open` also
  applies a staged restore before any connection opens, so a restore interrupted by
  a quit completes at the next launch; a damaged staged file is discarded and the
  current data opens.
- **Export:** versioned JSON (`clewExportVersion: 1`) of definitions + facts,
  including soft-deleted items and voided facts, which is a complete and lossless
  round-trip at the database's millisecond precision (times are ISO 8601 UTC with
  milliseconds). Settings › Export… writes it through a save panel
  (`com.apple.security.files.user-selected.read-write`). Markdown daily notes (Obsidian) are
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
| LaterReview | union by `id`; void is monotonic |
| DayReflection | one row per `localDay`; last writer wins by `updatedAt` |
| Item, Reminder, Settings | **row-level** last writer wins by `updatedAt` (every definition table has `updatedAt` + `deletedAt`). Field-level merge, if two devices editing different fields of one item ever matters, uses CKSyncEngine's server-record conflict callback with stored system fields; decided in v2 |
| `Award.voidedAt` | monotonic |
| WatchProgress | newest `observedAt` wins |
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
- **Gateway:** contract tests against the shared examples in `Contract/v1`;
  auth/Host/Origin negative tests; listener tests over real loopback sockets.
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
