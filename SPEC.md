# Clew v1 — Spec

*A clew is the ball of thread Ariadne gave Theseus to find his way through the
labyrinth. Clew is a thread through your day: what's left, what's done.*

Status: draft, 2026-11-08. Not started.

## The problem

Many goals (courses, videos and articles, job applications, exercise), but plans
don't hold. Reminders failed before because they were **inconvenient and not
interesting**. Long backlogs feel overwhelming, so nothing gets finished.

What works: **seeing the list**. Something left to do is the warning. Everything
done means a good day. Visible progress ("10 of 30") makes finishing satisfying.

## v1 in one picture

```
 ☑︎  4/6                        ← menu bar title (icon + done/total)
 ─────────────────────────────────────
 ✓ Exercise
 ✓ Apply to 1 job
 ○ ML course 🔗   ███████░░░░░░  10/30  −
 ○ Watch later 🔗 ████████░░░░    2/3
 ✓ Read 1 article
 ○ Stretch
 ─────────────────────────────────────
 + add                       Later (12)
```

## In scope

1. **Menu bar list.** A SwiftUI `MenuBarExtra`. The title shows `done/total` for today.
   Click it to open today's list. No main window is required.
2. **Item kinds.**
   - *Once*: done on a chosen day; if not done, it quietly moves to tomorrow.
     Saved links in the Later pile behave the same once picked for a day.
   - *Repeating*: daily, chosen weekdays, or N times per week. Once a weekly
     target is met, the item leaves Today's list until next Monday, unless you
     ticked it today.
   - *Counted goal*: a total (e.g. 30 videos). One click is `+1`; click again
     to log more. The bar shows progress in the current round; the item counts as
     done today once you've added at least one. **Reaching the total means the goal
     is reached:** Clew congratulates you and counting stops until you choose
     *Next round* (same total, from zero), *Raise target*, or *Done* (it leaves the
     list after the day). Every round stays in the history; the Daruma's second eye
     comes in v1.3.
3. **Links.** Any item can have a URL. The small link mark after its title opens
   it in the default browser. Pasting a link into `+ add` fills in the page's title,
   which you can edit before saving.
4. **Done in one click.** Click `○` to mark it done (counted goals: +1). If rating
   dots are switched on (Settings, off by default), five small dots (how it felt:
   rough, meh, okay, good, great) then appear at the right end **of the same row**
   as a hint, fading if unused; hovering there later shows them again to rate or
   change today's rating. Counted goals show no hint (it would hide the count while
   ticking): hover their bar to rate; the dots take the bar's place and `−` stays. The row never changes
   height and the dots never cover the `+1` target, so rapid ticks can't mis-click.
   Optional; they fade after a few seconds. Ticked items stay visible until the day
   rolls over, so undo is always one click away.
5. **Later pile.** Choosing "Later" in `+ add` puts an item (a link or not) in a
   hidden pile, and a short line confirms it ("Saved to Later (13)"). A pasted link
   goes to Today like anything else unless Later is chosen. The pile's count is
   shown, its contents aren't. "Pick 1–3 for today" moves items onto the list.
   Items untouched for 6 weeks get a "still want this?" in the Later picker, with
   **Keep** (its 6 weeks start again) or **Let go** (removed; Settings counts it). Saying no counts as a win. Any item can be deleted (in Later:
   `×`; on Today: right-click). Delete hides it for good; its history is kept.
6. **Gentle reminders** (optional, per item, off by default). One notification at
   a chosen time on each day the item is on Today and not done yet, with **Done**,
   **Later** (once-items and links only: moves it to the Later pile) and **Open**
   (only when it has a link). No repeats within a day, no escalation.
7. **Day summaries** (each optional): morning "6 today" at 9:00, evening "5/6 done"
   at 21:00, both changeable. Short, friendly, never a list of failures. A day
   with no ticks gets an encouraging line instead of "0/6".
8. **Local data.** A SQLite database (GRDB) in Application Support. One-click JSON
   export. No account. The only internet use is fetching a pasted link's title: one
   load of that page (and its redirects), no cookies, nothing else sent. While a
   browser is paired (v1.1), Clew also listens on this Mac only (`127.0.0.1`) for
   its extension.
9. **Launch at login** (`SMAppService`), toggled in a small Settings window.
10. **Task details.** Clicking a row opens its details. Habits and goals: a 16-week heatmap (done days
    filled, other days a quiet gray, never red), days done this week / in the last
    30 days / all time (goals: this round, rounds done, all-time total), and Edit /
    Delete. Once-tasks, links and videos: where it is, watch progress, a short
    history, and Open (see Decisions, 2026-11-09). No streak counts.
11. **Your order.** Drag rows to reorder them (or Move Up / Move Down). Ticking never
    moves a row. Sorting rules wait until manual order isn't enough.
12. **Backups.** A compressed copy every day on this Mac (the last 14 days, plus 8
    weeks before that). Settings › Restore… brings one back; the current data is
    saved first, so a restore can be undone.

## Design rules (from ADHD/CBT practice)

- **Point of performance** (Barkley): the list is always one glance away, in the menu bar.
- **Chunk big goals** (Safren, CBT for adult ADHD): every long goal becomes
  a visible count of small steps.
- **Distractibility delay** (Safren): a new idea goes to Later in one action,
  so it doesn't derail the current task.
- **No shame.** No red, no streaks, no "missed" counters. Unfinished items roll
  forward silently. Celebrate what got done.
- **Minimal text.** Labels and numbers. No paragraphs, no chatty coaching.
- **Tone:** a friend. Encouraging, never pushy.

## Out of scope for v1 (planned later)

- **Daruma goals and badges.** Paint one eye when a counted goal starts and the
  second when it's finished. Levels come from lifetime totals.
- Opt-in AI coach: recap, Later suggestions, quick start (see docs/AGENT.md).
- Sync with Dayflow (its local JSON API: `GET /api/day`, `PATCH /api/tasks/:id`).
- iPhone, iCloud sync, Obsidian export.

## Done means used

v1 is done when it has been **used on 5 of 7 days for two weeks**, not when its
tests pass. Clew records active days locally (a day with at least one tick) and
shows them only in Settings. Until that bar is met, the next work is fixing whatever
stopped daily use, not adding features.

## Decisions (2026-11-08)

- **Watch Later import (v1.1, 2026-11-09):** a paired Chrome extension copies
  YouTube's Watch Later into Clew when the Watch Later page is opened. A video removed
  from Watch Later **counts as finished** (*changed* 2026-11-10, user decision: before,
  it just left Clew and an unticked one was never recorded): one not ticked yet gets a
  tick dated the day Clew saw it gone, whether or not any progress was seen, and it
  stays in the collection's Done group. "Not finished" (right-click) takes it out of
  Done and the heatmap. This happens only when the page showed the whole list (never
  from an empty list); a video re-added comes back, to watch again (its automatic tick
  is undone; one the user made stays). What the user deleted stays gone.
- **X bookmarks (v1.1, 2026-11-10):** the second collection ("X bookmarks  5 to
  read ›"). A post's title is the title of the X Article it shares, else its own text
  (not a quoted post's), else "Post by @name". **Adding:** opening Bookmarks in Chrome
  (x.com/i/history, where X moved it; the Likes tab is ignored) reads the posts
  as you scroll (newest first, so new ones are seen at once), and bookmarking a post
  anywhere on x.com in Chrome adds it right away. **Removing = read** (same rule as
  Watch Later): unbookmarking in Chrome marks it read at once. The page shows no count
  and loads as you scroll, so it is never compared as a whole list; instead the **gap
  rule**: Clew remembers the order it last saw, and a post missing from *between* two
  posts still on the page (seen without a break from the top) was removed, so a
  removal on the phone is caught the next time Bookmarks is opened in Chrome and
  scrolled past where it was. Nothing below what was seen is decided. A post its author
  deleted also disappears, so it counts as read (accepted). Posts bookmarked again on
  the phone jump to the top and are never taken as a gap; in the rare case where only
  such posts were seen, a post can wrongly count as read ("Not read" undoes it). Bookmarked again: back to
  read. "Not read" (right-click) undoes an automatic "read".
  These automatic removals are not counted as the user's "let go". The same rule will
  apply to X: unbookmarking a post means it was read. Pairing: Settings › Browser
  shows a 6-digit code.
- **Collections (v1.1, 2026-11-09):** an imported list is **one collection**, not one
  task per video: a row below the tasks, after a thin divider and with no heading
  ("YouTube Watch Later  9 to watch ›", "X bookmarks  5 to read ›"; *changed* 2026-11-10 from
  "1 of 3", since Done keeps growing). It has no circle and does not
  count toward today's `done/total`. Its videos never appear on Today, in Later or in
  Pick (*changed*: they were Later items with their own details page). The row stays
  while the collection has anything finished, even if the list is emptied, so its
  heatmap stays reachable. Clicking it opens its page: a heatmap of days a video was ticked, ticked this
  week / last 30 days / all time, and the whole list (In progress, most watched first;
  Not started, newest first; Done, folded, including videos that left the list).
  Each video has a circle (undo is for today's tick, and only while it is on the list)
  and a title that opens it. Each list can be turned **off** in Settings › General ›
  Lists (2026-11-10): its row is hidden and imports are refused (the extension says
  so); what it holds stays and comes back when it is turned on.
- **Watch progress (v1.1, 2026-11-09):** read only from the red bars on the Watch
  Later page, when it is opened (not while a video plays: simpler, and it covers
  videos watched on other devices). Shown on the video's row in its collection, in
  the chosen bar style. It never ticks anything (a video ticks when it leaves Watch
  Later, whatever its progress; see Watch Later import).
- **Progress bars (2026-11-09):** Settings › General › Progress bars picks one of two
  styles for counted goals, collections and started videos: *behind the title* (the row's rounded
  background fills from the left, default) or *under the title* (a long bar under the
  name, almost to the row's end) or *no bar*. The short bar beside the count is gone;
  `10/30` stays. Pick shows a link's site ("medium.com", no "www.") but not for
  YouTube videos.
  The same bar will show a focus timer's time later.
- **One-off details (2026-11-09):** once-tasks and saved links have no
  heatmap (videos had this page too until they moved to their collection's page). Their details show where the item is (In Later, On Today, Done Nov 9),
  watch progress for videos, a short history (saved, picked, kept, done · felt), and
  Open video / Open link.

- Weeks start on **Monday**; "N× per week" items reset then.
- A counted goal's step is always **+1** per click.
- The rating row is offered **every time**, and is always skippable.
- Ratings are 5 points (rough … great), shown after a tick and on hover; Settings has
  a sidebar: General, Summaries, Progress, Data (2026-11-09).
- "Still want this?" lives only in the Later picker; untouched = not saved, edited,
  moved to Later or kept for 42 days. Rating dots are built off by default, as a
  Settings switch (2026-11-09).
- Clicking a row opens its details; the link mark, not the title, opens a link.
  Goal bars align in one column. Rows can be dragged to reorder (2026-11-08, after use).
- Reminders fire on every day the item is on Today until done, once per day; "Later"
  moves a once-item or link to the Later pile; "Open" appears only for links
  (2026-11-08, v1b).
- Counted goals have rounds; reaching the total stops counting until the user picks
  next round, a higher target, or done (2026-11-08, after first use).
- A pasted link goes to Today by default, not Later; `↗` is replaced by a clickable
  title with a link mark (2026-11-08, after first use).
- Pasted links get their page title fetched (2026-11-08, after first use); this is
  the app's only internet use (the v1.1 extension connection stays on this Mac).
- The menu bar title is an icon plus `done/total`, not the word "Clew" (2026-11-08, v1a).
- A counted goal's undo is a small `−` beside its count, shown only after a `+1` today;
  it removes the last `+1`. It sits apart from the circle so rapid ticks can't hit it
  (2026-11-08, v1a).
- Summary defaults: **9:00** and **21:00**, off until switched on.

## Open question

1. Which global hotkey, if any, opens the list? (v1 can ship without one.)

## Tech

Swift 6, SwiftUI, macOS 14+, XcodeGen (`project.yml`), GRDB. Unit tests in a
framework target so they run without launching the app. Copy
`install-local.sh` and `LoginItem.swift` from Tact, minus its Accessibility
signing step. App Sandbox stays **on**: Clew needs no Accessibility permission.
