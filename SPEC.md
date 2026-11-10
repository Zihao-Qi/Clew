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
   its extension. With calendar access (v1.2), Clew reads today's events from macOS
   Calendar on this Mac; it never stores or writes them.
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
  is undone; one the user made stays). What the user deleted stays gone (for X, a
  bookmark click is the one exception; see "X bookmarks").
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
  deleted also disappears, so it counts as read (accepted). A post deleted in Clew
  comes back when bookmarked again with a click (*changed* 2026-11-10: it stayed
  gone); a scan never brings it back, since it cannot tell "still bookmarked" from
  "bookmarked again". A scan also cannot undo a removal made in the last 10 minutes
  (a stale tab, or rows read just before the click); a click can. Posts bookmarked again on
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
  Not started (posts: To read) in the site's own order, Watch Later's or X's newest
  bookmark first (*changed* 2026-11-10 from "newest first", which gave no order to
  videos imported together); Done, folded, including videos that left the list).
  Each video has a circle (undo is for today's tick, and only while it is on the list)
  and a title that opens it. Deleting an item in Clew takes it out of the heatmap and
  the counts too (*changed* 2026-11-10). Each list can be turned **off** in Settings › General ›
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
- **Focus timer (v1.2, 2026-11-10):** a tomato clock on a task on Today. Right-click
  the row → Focus → **10, 25 or 45 minutes** (*changed* the same day: a ▶ on hover sat
  before the count, so it moved between goal and plain rows); one timer at a
  time (a running focus must be stopped first; a break is simply replaced). The task's
  bar fills with the time in the chosen bar style, and the menu bar shows the
  countdown. While it runs, the time, Pause and Stop sit right after the title (a long
  title truncates; nothing else moves); sleep and quitting lose nothing. When time
  is up a notification fires and the row asks **Done / +1, 5 more min, Break, Stop**;
  it never ticks by itself. **Break:** 5 minutes, offered when Settings › General ›
  Focus timer › "Offer a break after focusing" is on (default on), with its own
  notification. A timer whose task leaves Today ends. **Recording (step 2):** a focus
  that is stopped, finished with Done, or followed by a break is saved as a session of
  its real minutes (pauses left out, at least half a minute; a break never counts), on
  the day it started. Settings › Focus timer › "Record focus time" (default on) turns
  that off; sessions already saved stay. **By hand:** the task's details › Focus › "Add
  time…" (a day up to today, 1–720 minutes), always allowed, since the timer may be
  forgotten or the Mac not there. Details show "N this week · N in all" and the latest
  sessions, each removable (a void).
- **Day timeline (v1.2, 2026-11-10):** today's hours, **above the list in the menu**,
  so a plan and the list are one glance. Settings › General › "Show the day timeline"
  (default on) turns it off and the menu is as before. About **4 hours show** (about
  60 points an hour), it scrolls up and down through Clew's day (4 a.m. to 4 a.m.), and
  it opens scrolled to now, with a quiet line at the current time; the menu grows taller
  by that much, but never past the screen (the list scrolls when it must). **Today
  only:** no tomorrow, nothing planned ahead. Nothing on it is red or says "missed".
  - **Placing:** drag a task's row from Today's list onto an hour (the timeline scrolls
    when the drag nears its top or bottom edge). It drops as a **30-minute block**,
    snapped to 15 minutes; drag the block to move it and its bottom edge to resize it
    (15 minutes at least, ending at 4 a.m. at the latest). Only tasks on Today can be
    placed; the collection rows cannot. Blocks may overlap each other and events;
    overlapping ones sit side by side. A task's row shows the start of its next block
    not yet ended ("10:00"). **Unplacing:** drag the block back onto the list.
  - **Without dragging** (and for VoiceOver): the row's right-click › **Put on
    timeline…** and the block's right-click › **Move to…** open a small start-time and
    length picker; the block's right-click also has **Length** (15, 30, 45, 60, 90
    minutes) and **Remove block**. Each is also an accessibility action.
  - **One block is the easy case:** dragging a task's row again **moves** its block
    that has not ended (the earliest, if several); if all its blocks have ended, it
    adds a new one. A second block before then comes only from the block's right-click
    › **Add another block** (right after it; not offered when that would pass 4 a.m.).
  - **A block's end ticks the task** (*new rule*: until now only the user and a
    finished external list ticked; the focus timer still never ticks by itself). It is a
    real tick, dated the block's day: the row is done, it counts on the heatmap and in
    the week, and a counted goal gets **+1**. **A block decides once**, when its end
    passes (or at once, if it is placed or changed so that it has already ended): it
    ticks, or it skips. The outcome is kept; only changing its end makes it decide
    again. It **skips** when the task needs nothing: a task already done today (not a
    counted goal), a counted goal whose total is reached, or a tick **made by hand since
    the block was placed** that no earlier block used (each hand tick covers one block,
    so ticking by hand before the end never counts twice; the circle, `+1`, a
    reminder's Done and a focus timer's Done are all "by hand"). A focus timer's Done
    adds nothing when a block of the same task ticked while that timer ran (one sitting,
    one tick). If the Mac sleeps or Clew is not running at the end, the block decides
    when Clew runs again, still for its own day, even after 4 a.m.; a block ending at
    exactly 4:00 belongs to the day it ends.
  - **Undo:** right-click a block that ticked › **Not finished**, or untick the row as
    usual; the block stays, quieter, and does not tick again. **Changing a block's end**
    (move, resize) undoes its tick and lets it decide again, also after Not finished.
    **Removing** a block that ticked also undoes its tick (the tick belongs to the
    block); ticks made by hand are never touched. **Rounds:** once a counted goal's next
    round has started (or its target was raised), a block whose tick came before that
    keeps the tick: it can still be removed (tick kept) but not moved or un-finished.
    **Yesterday:** a tick made after 4 a.m. for the day before (the Mac was asleep)
    shows one line above the list, "Ticked for yesterday: Write intro · Not finished",
    until dismissed or the next rollover.
  - Blocks are **not focus time**: only the focus timer and time added by hand are
    recorded. A focus timer can run on a task with a block.
  - **Leaving Today:** moving a task to Later or deleting it removes its blocks for
    good (blocks not ended never tick; ticks already made stay). If it comes back the
    same day, it comes back without blocks. Blocks belong to their day: at 4 a.m. the
    timeline starts empty and an unfinished task rolls forward as usual, without its
    block. The rollover is not leaving Today: a block that ended the evening before still
    decides.
  - **Start alert:** "Write intro · now until 10:30" when a block starts, with **Open
    Clew**. Settings › Notifications › "Alert when a block starts" (default on). None
    for a block placed after its start or a task already done. Notification permission
    is asked when the first block is placed (if this is on); if it is denied, Settings
    says so.
  - **Calendar events (step 2)** show on the timeline as **read-only** blocks in their
    calendar's colour: title and time, nothing to click, never ticked, never counted,
    never alerted by Clew (Calendar has its own alerts). All-day events sit as a thin
    line at the top. Declined events are hidden. Clew reads **every calendar in macOS
    Calendar** (Google, iCloud, Exchange too, once added in System Settings › Internet
    Accounts); Settings › Calendar lists them with checkboxes, and Clew remembers only
    the ones unticked, so a new calendar shows by default. Clew **never writes to a
    calendar**, and events are read live: never saved, exported or sent anywhere.
    Access is asked only when "Show your calendar" on the timeline (or in Settings) is
    clicked; without it the timeline works with tasks alone.
  - **Steps:** (1) the timeline with task blocks, ticks and start alerts; (2) calendar
    events.
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
signing step. App Sandbox stays **on**: Clew needs no Accessibility permission. The
day timeline's events (v1.2) need the sandbox's Calendars entitlement
(`com.apple.security.personal-information.calendars`), an
`NSCalendarsFullAccessUsageDescription`, and full access: macOS 14 offers only full or
write-only access, no read-only, so the prompt text says Clew only reads.
