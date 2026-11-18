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
 ☑︎  3/4                        ← menu bar title (icon + done/total: Today, plus anything ticked below)
 ─────────────────────────────────────
 (day timeline)
 ✓ Exercise
 ✓ Apply to 1 job
 ✓ Read 1 article
 ○ Stretch
   Goals & Later
 ○ ML course 🔗   ███████░░░░░░  10/30
 ○ Book pages     ███░░░░░░░░░ 120/500
 ○ An article to read 🔗
 ─────────────────────────────────────
 YouTube Watch Later       9 to watch ›
 ─────────────────────────────────────
 + add                              ⚙︎
```

## In scope

1. **Menu bar list.** A SwiftUI `MenuBarExtra`. The title shows `done/total` for today.
   Click it to open today's list. No main window is required. A global shortcut also
   opens the list (default **⌘.**, changeable in Settings › General). It uses a
   Carbon hotkey, so the sandbox stays on and Clew needs no Accessibility permission
   (2026-11-11).
2. **Item kinds.**
   - *Once*: done on a chosen day; if not done, it quietly moves to tomorrow.
     Saved links in the Later pile behave the same once picked for a day
     (*changed* 2026-11-15: a Later item moved to Today is there for that day only).
   - *Repeating*: daily, chosen weekdays, or N times per week. Once a weekly
     target is met, the item leaves Today's list until next Monday, unless you
     ticked it today.
   - *Counted goal*: a total (e.g. 30 videos). One click is `+1`; click again
     to log more. The bar shows progress in the current round; the item counts as
     done today once you've added at least one. It lives in **Goals & Later**, not
     on Today, and has no schedule (*changed* 2026-11-15; see "Today and Goals &
     Later"). **Reaching the total means the goal
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
5. **Later.** Choosing "Later" in `+ add` puts an item (a link or not) in **Goals &
   Later**, the second list in the menu (*changed* 2026-11-15: it was a hidden pile
   with a count and a "Pick 1–3 for today" screen; see "Today and Goals & Later"). A
   pasted link goes to Today like anything else unless Later is chosen. The old
   "Still want this?" (Keep / Let go after 6 weeks untouched) is gone (*user*,
   2026-11-15). Any item can be deleted (right-click › Delete, or the Delete key).
   Delete hides it for good; its history is kept.
6. **Gentle reminders** (optional, per item, off by default). One notification at
   a chosen time on each day the item is on Today (*changed* 2026-11-15: or in Goals
   & Later) and not done yet, with **Done**,
   **Later** (once-items and links only; *changed* 2026-11-15: removed) and **Open**
   (only when it has a link). No repeats within a day, no escalation.
7. **Day summaries** (each optional): morning "6 today" at 9:00, evening "5/6 done"
   at 21:00, both changeable. Short, friendly, never a list of failures. A day
   with no ticks gets an encouraging line instead of "0/6".
8. **Local data.** A SQLite database (GRDB) in Application Support. One-click JSON
   export. No account. The only internet use (besides the opt-in update check below) is fetching a pasted link's title: one
   load of that page (and its redirects), no cookies, nothing else sent. While a
   browser is paired (v1.1), Clew also listens on this Mac only (`127.0.0.1`) for
   its extension. With calendar access (v1.2), Clew reads today's events from macOS
   Calendar on this Mac; it never stores or writes them. Only if turned on in
   Settings › About (off by default, 2026-11-13), Clew also asks GitHub once a day
   whether a newer release exists (see "About and updates").
9. **Launch at login** (`SMAppService`), toggled in a small Settings window.
10. **Task details.** Clicking a row opens its details. Habits and goals: a 16-week heatmap (done days
    filled, other days a quiet gray, never red), days done this week / in the last
    30 days / all time (goals: this round, rounds done, all-time total), and Edit /
    Delete. Once-tasks, links and videos: where it is, watch progress, a short
    history, and Open (see Decisions, 2026-11-09). No streak counts.
11. **Your order.** Drag rows to reorder them (or, with VoiceOver, Move Up / Move Down;
    *changed* 2026-11-18: no longer in the right-click menu), in Today and
    in Goals & Later alike. Ticking never moves a row. Sorting rules wait until
    manual order isn't enough.
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
shows them only in Settings (last week's card, 2026-11-15, shows the week's ticks, not
active days). Until that bar is met, the next work is fixing whatever
stopped daily use, not adding features.

## Decisions (2026-11-08)

- **Today and Goals & Later (user, 2026-11-15; Fable review).** Long-term goals on
  Today made a finished day read "3/5": they are worked on now and then, never all
  done in a day. The menu now has **two visible lists**, one under the other, and only
  the first counts. A folded row or submenu was rejected (it adds steps and hides the
  tasks).
  - **Today** (under the day timeline): once tasks and links planned for today or
    earlier (unfinished ones still carry over, as before), habits on their days, and
    anything from Goals & Later **moved to Today** for today. The menu bar's
    `done/total`, the morning and evening summaries and the "all done" line count
    Today, plus any Goals & Later item ticked today (it counts without moving: a
    finished day with one goal +1 reads "4/4", never "3/3 +1").
  - **Goals & Later** (a divider line, then a quiet section label lined up with the
    circles, then its rows; *changed* 2026-11-16 after use: the line was missing and the
    label sat at the titles; Today has no label, the timeline above says it is today): every counted goal
    that is not reached (see below), and every Later item (once tasks and links saved
    for no day) that is not done. Its rows look and work like Today's (circle, `+1`,
    bars, link mark, a link's site as Pick showed it, details, rating, right-click,
    the Delete key) and have their own order, dragged as on Today; Move Up / Move
    Down stop at each list's ends. New items go to its end. It is always shown in
    full; when the menu reaches the bottom of the screen, Today and Goals & Later
    scroll together (and while a row or a block is dragged near the list's top or
    bottom edge, the list scrolls by itself, faster nearer the edge; *user*, 2026-11-18) (the timeline above and the collection rows and footer below stay
    put; it opens scrolled to the top, and scrolls by itself while a row is dragged
    near its edge). With nothing in it, its label is hidden too.
  - **Empty Today:** "Nothing for today." (or "Everything is on the timeline.") stays
    above the Goals & Later label, as now.
  - **Add** keeps its four kinds: Today and Habit go to Today; **Goal** and
    **Later** go to Goals & Later. A goal has a total, no "Repeats" and no time slot
    (both removed). Adding returns to the list, where the new row can be seen
    ("Saved to Later (13)" is gone).
  - **Moving to Today** (for today only): drag a Goals & Later row into Today (it
    lands in the gap where it is dropped), or onto an hour of the day timeline (it is
    placed there and goes to Today's end), or right-click › **Move to Today** (Today's
    end). It then shows in Today until the rollover; the next day it is back in Goals
    & Later at its old place, unless it was done (a ticked once task or link leaves
    for good, as on Today; a goal stays). Dragging it back down or right-click › **Move
    to Goals & Later** undoes the move for today:
    its blocks are removed as when any task leaves Today (ended blocks keep their
    ticks; ticks stay).
  - **Moving to Later:** a once task or link on Today that has no tick can be
    dragged down into Goals & Later (into the gap), or right-click › **Move to
    Later** (its end). Habits stay on Today on
    their days (they cannot be dragged down).
  - **Ticking in Goals & Later** counts today and never moves the row; the row shows
    ticked until the rollover, as on Today, and can be undone. A ticked once task or
    link is done (it leaves the next day). A block of an item moved to Today ticks it
    at its end, as any block; a late tick after the rollover goes to the block's day.
  - **A reached goal** shows its congratulation and choices (Next round, Raise
    target, Done) on its row, wherever it is, on the day it was reached; from the next
    day it is hidden, unless Next round or Raise target was chosen (as before). A goal
    reached by a late tick shows them on its row in Goals & Later; that tick is the
    earlier day's, so it does not count in today's `done/total`.
  - **All done:** when Today's count is complete (done equals total and the total is
    at least 1, including a Goals & Later item ticked today), one quiet line, "All done
    for today", shows above Today's rows (in place of "Nothing for today." or
    "Everything is on the timeline."); otherwise nothing shows (never "2 left").
  - **Focus** on a Goals & Later row moves it to Today first (*user*: focusing on it
    makes it part of today); moving it back, deleting it or the rollover ends a
    running timer as when any task leaves Today.
  - **"Still want this?" is gone** (*user*, 2026-11-15: rather than asking on rows,
    the user deletes what they no longer want). Keep and Let go go with it; Settings ›
    Progress shows no "Let go from Later" any more, and earlier answers stay in the
    history only.
  - **Gone too:** the footer's "Later (N)" button, the "Pick 1–3 for today" screen and
    its ⌘L shortcut, and the "Saved to Later (N)" line.
  - **Goals lose their schedule and time slot.** A goal's "Repeats" and its
    repeating time slot are removed: it is placed on the timeline only by moving it,
    for today.
  - **Reminders work the same in both lists** (*user*, 2026-11-15: a goal may want
    its nudge without being moved, and two behaviours would be odd). A reminder fires
    once a day at its time while the item is in **either list** and still needs
    something today: not done today, and for a goal not reached. So a goal in Goals &
    Later with a reminder nudges every day it has no +1 yet; a habit still only on its
    days. The notification's **Later** button is removed (*user*, 2026-11-15: a
    reminder is a nudge the user asked for; moving tasks is done in the menu); it
    keeps **Done** and **Open**. A reminder set earlier on a Later item now fires
    daily too (accepted: it was set on purpose; Edit turns it off).
  - **Today or every day** (*user*, 2026-11-15). When "Remind me" is switched on, a
    choice beside the time picks **Today** or **Every day** (default Every day, as
    reminders worked so far; existing reminders are Every day).
    - **Every day:** as above, each day the item is in a list and still needs
      something.
    - **Today:** once, at that time on the Clew day it was set (the rollover rule),
      if the item still needs something then; after that day it is spent and Edit
      shows "Remind me" off again. A time already past today cannot be chosen with
      Today: the row says "That time has passed today" and Save is refused until the
      time or the choice changes (nothing is saved; an existing reminder is
      untouched; no notification fires at once). Between midnight and 4 a.m. the
      Clew day is still yesterday, so "Today 9:00" set then is refused as passed (the
      rollover rule; not a bug). Changing the time or the choice later the same day
      sets it again for today.
    - Either way it fires at most once a day (unless its time or choice is changed
      that day), and never for an item done today, a reached goal, or a habit not due
      that day. Details show "Reminder 18:00" or "Reminder 18:00 today"; a spent
      one-day reminder shows nothing.
  - **Existing data just moves**, nothing is asked: on the first launch of this
    version every goal's schedule becomes none and its time slot is removed (past
    blocks and ticks stay); a goal with a live block today is moved to Today for
    today, so its block stays. Later items show in Goals & Later; Today's once tasks
    and habits stay on Today; items picked from Later before the update are on Today
    already and carry over as once tasks.
  - YouTube and X rows sit below both lists, above the footer, as before.
  - Details say where an item is: "On Today", "In Goals & Later", "Done Nov 9".
  - VoiceOver: the label "Goals & Later" is a heading; every row has "Move to Today",
    "Move to Goals & Later" or "Move to Later" as actions, so nothing needs a drag.
  - **Moves slide** (user, 2026-11-18): a row moved from a menu or an action (Move to
    Today, Move to Goals & Later, Move to Later, Move Up / Move Down) slides to its new
    place, across the label too, instead of jumping there (about 0.3 s). A drag lands
    where it is dropped, with no slide.

- **Add explains each type (user, 2026-11-17).** A task's type cannot be changed
  after it is added (*user*: changing it was weighed and not allowed, since a goal's
  several +1s a day, its rounds and a habit's slot do not carry over cleanly; to
  change it, add it again). So Add says what each type is: one quiet line under the
  Today · Habit · Goal · Later choice, changing with it:
  - **Today:** "Done once. Stays on Today until you tick it."
  - **Habit:** "Comes back to Today when it repeats." (Not "on its days": a habit done
    N times a week has none; it shows each day until the week's count is met.)
  - **Goal:** "A total to reach, one +1 at a time. Lives in Goals & Later."
  - **Later:** "For another day. Waits in Goals & Later until you get to it." (It can be
    ticked there or moved to Today.)
  The line is secondary text, no icon, placed right after the choice (VoiceOver reaches
  it next; nothing is announced when the choice changes). Edit
  shows no type choice and no line. (A Today task can still go to Later by dragging
  it down or with Move to Later, as before.)

- **A habit cannot leave Today (user, 2026-11-17).** Dragging a habit (its row, or
  its block from the timeline) down into Goals & Later is refused (it would come back
  on its next day; a dropped block still leaves the timeline and its row stays on
  Today, as now). Instead of "That can't be done right now." (or, for a block, no
  word at all), the line that shows refused actions says **"Habits stay on Today. Change
  when it repeats in Edit."** (ticked today or not). A once task or link of Today's own
  (not one moved from Goals & Later, which can always go back) whose row is ticked today
  and dragged down says **"Done today. Undo the tick to move it."** Its block dragged
  down behaves as now (the block leaves the timeline, a block-made tick with it), so
  no hint. Nothing else changes (no new menu item; the hint shows only when it is
  tried).
  - **Refusal lines clear when the menu closes** (all of them, not only these), so a
    line never greets the next opening or the next day. They still clear at the next
    action that succeeds, as before.

- **A day for Later (user, 2026-11-17; Gemini Carbon review).** "Not today, Thursday" in
  one step: a task can wait in Goals & Later for a day, then come to Today **for that
  day** by itself, as if moved there by hand that morning (Distractibility delay:
  park it with a day, so it is not forgotten).
  - **What can have a day:** once tasks and links (not habits, goals, YouTube or X
    items). The day is a Clew day (it starts at the rollover, 4 a.m.), from tomorrow
    on; today or an earlier day cannot be chosen. One day at a time: choosing another
    replaces it.
  - **Where it is set:**
    - **Add:** with **Later** chosen, one optional row under the line: a checkbox **"On a
      day"** and the day as a button ("Thu, Nov 19"; default tomorrow) that opens the
      app's own month calendar right below it, on a light card; picking a day closes
      it, and checking the box opens it (*changed* after use, 2026-11-18: a switch and the
      system date field, whose calendar was small and looked foreign). While it is on, the line reads "Comes to
      Today on that day." Off adds a plain Later task, as now.
    - **Edit** of a once task or link with no tick (on Today or in Goals & Later): the
      same row. Turning it on for a task of Today's own makes it a Later task with a
      day; turning it off leaves a plain Later task; changing the date moves its day.
    - **Not in the right-click menu** (*changed* after use, 2026-11-18: *user*, the menu
      was getting complicated; "Later until › Tomorrow / Next Monday / Pick a day… / No
      day" and its Pick a day screen are gone). Edit is the one place, for VoiceOver too.
      The calendar is as wide as the menu; its outer days line up with the title and
      Save, and today keeps a thin ring.
  - **Giving a day** to a task of Today's own moves it to Later (as Move to Later: off
    Today, at Goals & Later's end, today's blocks removed). A Later task moved to Today
    for today goes back down first (as Move to Goals & Later). A task already in Goals
    & Later keeps its place.
  - **While it waits:** its row in Goals & Later shows its day in quiet secondary text
    at the row's end, lined up with the goals' counts (*changed* after use, 2026-11-18:
    after the title it looked crowded; a link's site stays after the title): "Tomorrow" for the next
    day, a weekday ("Thu") for two to six days on, otherwise the date ("Nov 27"). It can
    be ticked there (done; it leaves the next day, as any Later task), dragged within
    Goals & Later (its day stays), deleted or edited.
  - **Moving it to Today early** (drag up, Move to Today, an hour on the timeline,
    Focus) moves it for today as any Later task, and its day is dropped.
  - **On its day** it is on Today at the end, when Clew first refreshes that day (at
    the rollover, or on waking or opening; several arriving the same day keep the
    order their days were set in), and counts
    in Today's `done/total`. Nothing is announced. It can be dragged, placed on the
    timeline, focused on and moved back down, as any row moved to Today. **If it is not
    ticked that day** (*user*), the next day it is back in Goals & Later at its place,
    a plain Later task with no day, as any row moved to Today for a day. The same if
    the Mac was off or asleep all that day.
  - **Reminders:** while it waits, its every-day reminder does not fire (*user*: a task
    parked until Monday does not nudge before Monday). On its day it fires as on any
    Today row; afterwards, back in Later with no day, as for any Later task. A
    **Today** reminder set on a waiting task does fire that day (it was asked for that
    day). Clew's scheduled notifications for the coming days count it on Today on its
    day, and leave its reminder out on the days before.
  - **Details** show "Comes to Today Thu, Nov 20" while it waits. The history lists a
    day it was on Today only once that day has come, dated by that day; a day that was
    changed or removed before it came is not listed.
  - **Data:** no new field. A day is a `Plan` (the "moved to Today" fact) recorded now
    for that future day, with no Today place (`todaySortKey` nil). Changing or
    removing the day, or moving it early, voids that plan. On its day, Clew's first
    refresh gives it a Today place at the end: the plan is voided and a new one for the
    day inserted with a key (as a reorder does), in the order the plans were recorded.
    Only a Later task's nil-key plan is settled this way (moving a task by hand always
    gives it a place; a goal's nil-key plan, as from the v11 migration, keeps using the
    item's own `sortKey`, as now).

- **Last week's card (user, 2026-11-15; Fable review).** A reminder of how the last
  week went, because looking back at what got done helps the next start (Design
  rules: celebrate what got done). Weekly only: like a game's weekly reset, a missed
  day costs nothing (the user chose this over a daily card and a "welcome back" card;
  no easy-step suggestion; never a notification).
  - **Where:** a small card at the **very top of the menu**, above the day timeline
    (and above the calendar prompt and every timeline line), on the list screen only.
    The menu grows by the card's height, never past the screen (the rows give way, as
    for the timeline).
  - **When:** last week is the Monday-to-Sunday just before the week that holds
    today (Clew days: a week starts on Monday at Clew's rollover hour, 4 a.m.), even
    when Clew was not opened for weeks. The card shows **once**: the first time the
    menu opens on the list screen in a new week (by click or ⌘.), for that opening
    only. The menu closing (its window losing the keyboard, also to a system alert;
    a right-click menu or the hover peek do not), leaving the list (Add,
    Settings, details, a page) or × ends it, and it does not come back that week
    (*user*, 2026-11-15: it should not sit above the list). It never appears while
    the menu is open (a new week at the rollover, or a late tick, shows it the next
    time the menu opens), nor when going back to the list inside one opening (Esc
    from a page). An opening that is not on the list shows no card and does not use
    it up; neither does an opening with no card to show (switch off, no tick yet).
    Within the opening it was shown in, the card is fixed: it does not change if a
    tick is undone meanwhile. "Shown" is stored as that week's Monday, compared for
    equality, so setting the clock back never hides another week's card. Turning
    the switch off and on again in the same week shows it again if it was not shown
    yet. First launch ever: no card.
  - **In Settings too:** Settings › Progress has a "Last week" section with the same
    lines (no ×), so a card that went by too fast can be read later. It follows the
    same numbers and the same "only when something shows" rule (absent otherwise),
    ignores the switch and whether the card was shown, and is as fresh as the pane's
    other numbers (read when the pane opens or Settings comes forward). VoiceOver
    reads it as ordinary rows.
  - **Only when something shows:** the card (and the Settings section) exist only
    when done, watched or read is above 0 after the rules below; otherwise there is
    no card at all, not an empty one (focus time alone does not bring it).
  - **What** (minimal text, numbers, never a comparison, a drop or anything missed):
    - "Last week" and ×;
    - one line: "23 done" and, when focus time was recorded, "· 3 h 20 min focus"
      (the details page's format: "25 min", "1 h", "2 h 5 min"). **Done** counts each
      item that is not from a collection once on each day of the week it has a tick
      (once tasks, links, habits, goals; *changed* 2026-11-18, *user*: a goal counts
      once on a day however many +1s it got, so 40 pages read is 1, not 40; it was the
      sum of tick amounts). It equals the rise of "Done so far" over that week. "N
      done" is left out when 0;
    - when the week had any, one line for the collections: "4 watched · 2 read"
      (YouTube and X items, by the item's own source, ticked or counted finished that
      week; as on the collection page, items the user deleted are left out, items that
      left the site's list are kept). A list turned off in Settings has no number;
    - up to two highlights: the habits and goals done on the most days that week, at
      least two days each ("Exercise 4× · Read papers 3×"; *changed* 2026-11-18: a goal
      counts its days, not its +1s, as Done does; ties keep the list's order). Titles
      truncate; the count never does.
    - **Deleted items:** done and focus count every tick and session not undone, even
      of items deleted since (history is kept); only highlights and the collection
      numbers leave deleted items out.
    Ticks undone (voided) never count; ticks are counted on the Clew day they belong
    to (a tick at 1 a.m. on Monday belongs to Sunday's week). **The numbers are live**,
    not a snapshot: a Sunday block that settles on Monday, time added by hand to a past
    day, or a "Not finished" changes them, and can bring or remove the card.
  - **Off switch:** Settings › General › "Last week's card" (default on); it turns
    off the menu's card only.
  - VoiceOver reads the card as one element ("Last week: 23 done, 3 hours 20 minutes
    of focus, …"); × is "Close last week's card". Every number has its singular form.

- **Done so far (user, 2026-11-18; design: the "Clew progress line" canvas).** A line
  that only rises: everything got done, from the first tick (Design rules: celebrate
  what got done; it never dips, so a quiet week costs nothing).
  - **Counting** (*user*): each item counts **once on each day it has a tick**: a once
    task or link the day it is ticked, a habit each day it is done, a goal on each day
    it got any +1 (1 page or 40 pages: 1). YouTube and X items are left out (they have
    their own pages), as in last week's card. Undone (voided) ticks never count; ticks
    of items deleted since still count (history is kept). Days are Clew days (the
    rollover rule). Last week's card counts the same way.
  - **Where:** Settings › Progress, its first section, "Done so far", above Active days
    and Last week. Not in the menu.
  - **What:** the total ("1,284 done", large) and under it "since Sep 2" (the first
    tick's day) for All, "+N in the last year" for Year, "+N in the last 30 days" for
    30 days; a **range** choice **30 days · Year · All** (default All, remembered); the
    chart: a line of the running total per day (a soft fill under it, 3 or 4 light
    gridlines labelled at the right, a few date labels under it), from the range's
    first day (All: the first tick's day) to today, its bottom the total before the
    range, so a 30-day slope fills the chart. A small ring dot marks each day a goal
    reached its total (a goal deleted since keeps its dots, as its ticks keep counting) (the round's total: a later round's recorded total, round 1's
    the next round's or, with none, the goal's own). The caption under the section:
    "Each task once a day it was done. Dots: a goal reached."
  - **Hover:** a dashed guide at the day under the pointer and a small tip: "Nov 12 ·
    642 done · +9 that day" ("+0 that day" is left out on a quiet day). The line has no
    other interaction.
  - **Before the first tick:** no total; the chart area says "Your first tick starts
    the line." over a dashed baseline.
  - **Fresh** as the pane's other numbers (read when the pane opens or Settings comes
    forward). Light and dark follow the system; the line is the accent colour.
  - **VoiceOver:** the chart is one element: "Done so far: 1,284. 232 in the last 30
    days." (the range's rise), plus the system's chart description, so its audio
    graph can play the line.
  - **A goal's exact numbers** go in its Details (below), not on the line.

- **A goal's days: Bars or Heatmap (user, 2026-11-18).** A goal's Details show its
  counts per day one of two ways, chosen with a small **Bars · Heatmap** switch on the
  chart; the choice is remembered for all goals (default Bars).
  - **Bars:** the last 30 days, one bar a day, its height that day's +1s (all rounds;
    a day with none has no bar), a dashed line at the highest day with its number; the
    first day's date at the left, "Today" at the right. Hover a bar: "Nov 15 · +38".
    Title "Last 30 days".
  - **Heatmap:** the existing heatmap (16 weeks), unchanged. Title "Last 16 weeks".
  - Under either: "+364 on 22 days" for what is shown (left out when 0).
  - Habits keep the heatmap alone, with no switch (a habit counts once a day).
  - VoiceOver: the switch is a two-choice picker "Show as"; the bars read as one
    element ("Last 30 days: +364 on 22 days, most 38 on Nov 15") with the system's
    chart description.

- **About and updates (user, 2026-11-13).**
  - **Opening Settings closes the menu** (the gear button and ⌘,), like any menu
    item that opens a window: the menu closes first, then Settings comes forward. The Settings window is **720 × 520** (was 620 × 440).
  - **About** (sidebar icon `info.circle`) is the last section of the sidebar: Clew's icon, "Clew", "Version 1.5.0
    (6)" (from the app itself), "Made by Zihao Qi" with a link to
    github.com/Zihao-Qi, and a link "Clew on GitHub" to github.com/Zihao-Qi/Clew.
  - **How to upgrade**, always shown (a sandboxed app cannot tell how it was
    installed): "With Homebrew" and `brew update && brew upgrade --cask clew` with a
    Copy button (it reads "Copied" for 2 seconds); "Otherwise" a link "Download the
    latest release" to github.com/Zihao-Qi/Clew/releases/latest. Then: "The browser
    extension is on the same page (Clew-Extension zip); load the new one in your
    browser." Clew never installs anything itself.
  - **Check for updates automatically**: a switch, **off** by default. When on, Clew
    asks GitHub for the latest release when a check is **due**: on launch, on wake
    and every hour, it checks if the last attempt (automatic or Check Now, worked or
    not) was 24 hours ago or more, or never happened, or is in the future (the clock
    was set back). Turning the switch on checks at once if due. One `https` request to
    `api.github.com/repos/Zihao-Qi/Clew/releases/latest`, no cookies, no cache, a
    plain "Clew" user agent, nothing about the user or their data. Only the release's
    tag (`v1.5.1`) is read; its link is built from the tag
    (github.com/Zihao-Qi/Clew/releases/tag/v1.5.1), never taken from the reply. Drafts
    and pre-releases are never offered (GitHub's "latest" leaves them out).
  - **Check Now** asks at once, whether the switch is on or off; while asking it is
    disabled and reads "Checking…". Then one line says what it found: "Clew is up to
    date." or "Couldn't check for updates." (no network, an error reply, no release
    yet, or a tag that is not `v` plus numbers). An automatic check that fails says
    nothing.
  - Whenever a release newer than the running Clew is known (from any check that
    worked, kept across relaunches), About shows "Clew 1.5.1 is available." with a
    "Release notes" link, also after a later check failed. "Last checked" shows the
    date and time of the last check that worked (the system's abbreviated date and
    short time, e.g. "Nov 13, 2026 at 8:30 PM"), or "Never".
  - Versions compare by number, part by part (`1.10.0` is newer than `1.9.2`; a
    missing part is 0); a tag is `v` plus numbers, the running version is the same
    numbers without the `v`.
  - **The dot:** while a newer version than the running one is known and About has
    not been shown since it was found, the menu's gear button has a small dot
    (VoiceOver: "Settings, update available"), and the gear (and ⌘,) opens Settings at
    About. Showing About clears it: opening it, or a check finding the version while
    the Settings window is open on About and not minimized (in front or not); a
    still newer version brings it back. After upgrading, the known version is no
    longer newer, so there is no dot. No notification.
  - The switch and what the checks found belong to **this Mac**, not to Clew's data:
    they are not in the export, a restore does not change them, and they will not
    sync.
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
  and loads as you scroll, so it is compared as a whole list only once its **end** has
  been seen (below); until then the **gap rule**: Clew remembers the order it last saw,
  and a post missing from *between* two posts still on the page (seen without a break
  from the top) was removed, so a removal on the phone is caught the next time
  Bookmarks is opened in Chrome and scrolled past where it was. Nothing below what was
  seen is decided, unless the end was seen. **The end of the list** (*changed*
  2026-11-13, user: posts removed below the last remaining bookmark stayed in Clew for
  good): when the posts read without a break from the top reach X's last row, that row
  is on screen and empty (no text, no button: not a loading or "Retry" row), nothing is
  loading, every row above it held a readable post, and nothing changes for 3 seconds
  (checked again on each scroll and when sending), within 10 minutes of the page
  loading: then the scan is the whole list, and every post in Clew it did not see was
  removed (read), as with Watch Later. Never from an empty page, never a post Clew
  changed in the last 10 minutes (bookmarked, brought back or renamed: the page may be
  stale), and never more than 20 posts that are also more than half the list at once
  (then the gap rule alone, as before; a guard against a broken page). A short list
  ends after one scroll to the bottom; a long one when scrolled all the way down. A post its author
  deleted also disappears, so it counts as read (accepted). A post deleted in Clew
  comes back when bookmarked again with a click (*changed* 2026-11-10: it stayed
  gone); a scan never brings it back, since it cannot tell "still bookmarked" from
  "bookmarked again". A scan also cannot undo a removal made in the last 10 minutes
  (a stale tab, or rows read just before the click); a click can. Posts bookmarked again on
  the phone jump to the top and are never taken as a gap; in the rare case where only
  such posts were seen, a post can wrongly count as read ("Not read" undoes it). Bookmarked again: back to
  read. "Not read" (right-click) undoes an automatic "read".
  These automatic removals are not counted as the user's "let go" (*changed*
  2026-11-15: the user's let go is gone; the count with it). Unbookmarking a post
  means it was read. Pairing: Settings › Browser
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
  videos imported together); Done, including videos that left the list). **Every group
  starts folded**, with its count ("To read (4)"), each time the page opens, and a click
  anywhere on its header row unfolds it (*changed* 2026-11-13, user: only Done was folded,
  and only its small arrow opened it).
  **A peek on hover** (*user*, 2026-11-13): resting the pointer on a collection's row
  for about 0.1 s opens a small panel beside Clew's menu, like a macOS submenu, with
  only what is left (In progress, then Not started, as on the page), one title per line
  (one line each, truncated), and no heading above them; VoiceOver names the panel
  "To watch (3)" or "To read (4)" (*changed* 2026-11-13, user: no "To watch" title, and
  0.1 s, not 0.3 s, which felt slow). On macOS 26 it is drawn with the same glass as the
  menu (the older material looked darker beside it). Pressing a title opens
  it in the browser, as on the page (the browser comes forward and the menu closes, so
  one link per opening); nothing else is done there (no ticking, no Done group). The
  panel is 280 points wide, flush against the menu (no gap) on the side with room on
  the menu's own screen (left first, since Clew lives at the right of the menu bar),
  its top level with the row (moved up when it would pass the screen's bottom), at most
  about 12 lines tall (it scrolls beyond).
  - **Opens** only after the pointer *moved* onto the row (arriving on it by moving
    counts) and rested there; never under
    a pointer that did not move (the menu opening with ⌘., the list moving under it, or
    coming back from the page with Esc), never during a drag of a row or block, and not
    again after a click on the row until the pointer has left the row.
  - **Stays** while the pointer is on the row, inside the panel, or moving from the row
    toward the panel's side (crossing other rows on the way, like a macOS submenu).
  - **Closes** 0.2 s after the pointer leaves both and stops heading for the panel; at
    once on the row's click (its page opens), when a drag starts, when the menu closes
    or leaves the list (also by ⌘N or ⌘L; ⌘L is gone since 2026-11-15), and when nothing is left. The other
    collection's panel replaces it only after resting on that row; time spent heading
    for the open panel does not count as rest. Esc does what it does without the panel.
  - It never takes the keyboard, so the menu stays open and its keys keep working.
    Titles read "Open <title>" to VoiceOver; the page stays the way in for the keyboard.
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
  styles for counted goals and started videos (*changed* 2026-11-13: collection rows
  have no bar): *behind the title* (the row's rounded
  background fills from the left, default) or *under the title* (a long bar under the
  name, almost to the row's end) or *no bar*. The short bar beside the count is gone;
  `10/30` stays. Pick shows a link's site ("medium.com", no "www.") but not for
  YouTube videos (*changed* 2026-11-15: Pick is gone; Goals & Later rows show it).
  The same bar will show a focus timer's time later.
- **One-off details (2026-11-09):** once-tasks and saved links have no
  heatmap (videos had this page too until they moved to their collection's page). Their details show where the item is (In Later, On Today, Done Nov 9; *changed* 2026-11-15: In Goals & Later),
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
  so a plan and the list are one glance. Settings › General › Day timeline › "Show the
  day timeline" (default on) turns it off and the menu is as before. About **6 hours show** (*changed*
  2026-11-10 after use, from 4; about
  60 points an hour), it scrolls up and down through Clew's day (4 a.m. to 4 a.m.), and
  it opens with now a third of the way down (2 hours behind, 4 ahead; re-centred every
  time the menu opens; *user*, 2026-11-11), with a quiet line at the current time. It sits
  in its own inset card with a faint tint, its hour lines and blocks stopping short of the
  right edge, so it reads apart from the list; the block running now stands out a little
  (a stronger tint and an accent edge); the menu grows taller
  by that much, but never past the screen (the list scrolls when it must). **Today
  only:** no tomorrow, nothing planned ahead. Nothing of Clew's own on it is red or says "missed".
  - **Text** (*user*, 2026-11-13): titles the size of the list's tasks (13 points),
    times and hour labels 11. A block or event shows its time under the title only when
    it lasts **more than 30 minutes**; one of 30 minutes or less shows just the title (a
    slot block's "Done?" or a running focus timer follows it on the same line), centred
    in a 15-minute one. A counted goal's block shows its count ("10/30", as its row) at the
    right end of the title line, where the list has it; the title truncates first. A range names a
    shared AM or PM once: "9:00 – 10:00 AM" (24-hour clocks show none); a range past
    midnight shows both in full.
  - **Placing moves the task** (*changed* 2026-11-10 after first use: the row stayed in
    the list too, so it looked copied, not moved). Drag a task's row from Today's list
    onto an hour (the timeline scrolls when the drag nears its top or bottom edge): the
    task **leaves the list and lives on the timeline** for the day, as a **30-minute
    block** snapped to 15 minutes. Drag a block to move it and its bottom edge to resize
    it (15 minutes at least, ending at 4 a.m. at the latest). **Dragging a block back
    onto the list** removes it; a task with no blocks left is back in the list, in the
    gap it was dropped in (*changed* 2026-11-15: dropped in Goals & Later, an item
    moved to Today moves back, an unticked once task or link moves to Later, and
    anything else lands at Today's end). **One lifted card** carries what is dragged (*changed*
    2026-11-10 after use: a dashed outline and a different chip looked like other
    things): over the list it looks exactly like a row being reordered, and the rows
    slide apart where it would land; over the hours it is the block it would become, at
    the quarter hour under the pointer; one tint for both, and its shape changes
    smoothly as it crosses the line. Only tasks
    on Today can be placed (*changed* 2026-11-15: and Goals & Later rows, which move
    to Today); the collection rows cannot. Blocks may overlap each other and
    events; overlapping ones sit side by side. Tasks on the timeline still count in the
    menu bar's `done/total`. With the timeline turned off, every task is in the list.
  - **On a block** (right-click, also accessibility actions): **Done** / **+1** and
    **Undo** (the row's tick, by hand; *user choice*: right-click only, no circle on the
    block), **Focus** (the timer, with its controls there while it runs), **Move to…**
    (a start-time and length picker), **Length** (15, 30, 45, 60, 90, 120 minutes;
    lengths that would pass 4 a.m. are not offered), **Add another block** (right after it, the
    same length; not offered when that would pass 4 a.m.), **Not finished**, **Remove
    block**, **Delete**. Clicking a block opens the task's details.
  - **On today's timeline, in Edit** (*user*, 2026-11-18: the row's right-click ›
    Put on timeline… moved here, to keep the right-click menu short). Edit of a task
    that is not a habit (a once task, link or goal not reached, on Today or in Goals &
    Later; not a collection's item), while the timeline is shown: a checkbox **"On
    today's timeline"** with **"at [10:15] for [30 min]"** indented under it, as a
    habit's slot reads (a habit keeps its own repeating "On the timeline").
    - Opened with a block of today that has not ended: checked, at that block's start and
      length. Otherwise unchecked, ready at the next quarter hour for 30 minutes.
    - Save: checked, and new or changed → the task is placed there as dropping it on an
      hour does (its earliest block that has not ended moves, or one is added; a Goals &
      Later task is moved to Today, and a day for Later is dropped). Unchecked when it
      was checked → that block is removed, as Remove block does. Ended blocks and their
      ticks are not touched. Lengths that would pass 4 a.m. are not offered.
    - "On a day" and "On today's timeline" exclude each other: checking one unchecks
      the other (a day sends it to Later; the timeline brings it to Today).
    - Several blocks are still made with a block's Add another block.
  - **The row's right-click menu** (*changed* 2026-11-18): Undo, Details, Edit…, Focus,
    then Move to Today / Move to Goals & Later / Move to Later (whichever applies), and
    Delete. **Put on timeline…**, **Later until ›** and **Move Up / Move Down** are gone
    from it (*user*: keep the right-click simple). Move Up / Move Down stay as VoiceOver
    actions, so the list can be reordered without dragging.
  - **Times on the timeline** (Edit's "On today's timeline", a block's Move to…, a
    habit's slot; *user*, 2026-11-18):
    one time field, as Remind me has. Click the hour or the minutes, and the arrow keys
    (or the field's stepper) change that part; the minutes step a quarter hour and carry
    into the hour (8:00 ↓ is 7:45). A typed minute shows as typed, and becomes the
    nearest quarter hour when the field is left (8:37 → 8:30). Before 4 a.m. a time is
    the night at the timeline's end.
  - **The Delete key** deletes the task under the pointer, a row or a block, like the
    menu's Delete (*user*, 2026-11-10: delete is a real delete; taking a block off the
    timeline is Remove block or dragging it back). Every delete shows "Deleted “Write
    intro” · Undo" for a few seconds; Undo brings the task back with its reminder,
    without its blocks.
  - **Several blocks** are allowed (Add another block); the first comes from dragging the
    row or Edit's "On today's timeline".
  - **A new task from the timeline** (*user*, 2026-11-13). **Double-click** an empty
    spot (or a calendar event, which takes no clicks) and a small name box opens right
    there, like Calendar's: a **30-minute block** at the quarter hour under the pointer
    (cut at 4 a.m.), in the column the block will take (beside an event it overlaps), so
    nothing jumps on Return. It scrolls with the hours. Type a name and press **Return**:
    a **today task** is made and placed there in one step (its row's place, once it is
    back in the list, is at the end, as with `+ add`). A name Clew refuses (too long)
    keeps the box open with its text and the usual notice.
    - **Cancel:** Esc, a name that is empty or only spaces, clicking anywhere else, the
      menu closing, leaving the list (Add, Settings, details) and the rollover all
      close the box and drop what was typed; nothing is made. A click that closes it
      still does what it does (a circle ticks, a block opens its details). A
      double-click elsewhere on the timeline opens a new, empty box there. While an
      input method is composing (Pinyin, Kana), Return and Esc belong to it.
    - **Links:** a link pasted into the box works as in `+ add`: its page title is filled
      in, editable, and Return saves what the box shows. Copy the link first: switching
      to the browser closes the menu, and the box with it.
    - **No choices in the box:** the kind is a today task (*changed* 2026-11-17: a
      task's kind is never changed; a habit or goal is made in `+ add`), and the length changes by dragging the block's bottom edge.
    - **Past hours are allowed:** a block that has already ended ticks at once, as when a
      row is dropped there, so the task is made done (Not finished undoes it).
    - **While the box is open** the keyboard edits the name: the Delete key does not
      delete the task under the pointer, and the timeline does not re-centre on now.
    - Double-clicking a block opens its details, as a click does; the details ignore the
      second click, so it cannot land on their buttons.
    - VoiceOver gets a "New task on the timeline" action on the timeline, which opens
      the box at the next quarter hour (the day's last one if none is left). Without
      VoiceOver, `+ add` and then Edit's "On today's timeline" does the same.
  - **A block's end ticks the task** (*new rule*: until now only the user and a
    finished external list ticked; the focus timer still never ticks by itself). It is a
    real tick, dated the block's day: the row is done, it counts on the heatmap and in
    the week, and a counted goal gets **+1**. **A block decides once**, when its end
    passes (or at once, if it is placed or changed so that it has already ended): it
    ticks, or it skips. The outcome is kept; only changing its end makes it decide
    again. It **skips** when the task needs nothing: a task already done today (not a
    counted goal), a counted goal whose total is reached, or a tick **made by hand since
    the block was placed**, not undone, that no other block used (each hand tick covers
    one block, so ticking by hand before the end never counts twice; a hand tick a block
    used stays with that block: it covers it again after a move and is not freed when
    the block is removed; the circle, `+1`, a
    reminder's Done and a focus timer's Done are all "by hand"). A focus timer's Done
    adds nothing when a block of the same task ticked between that timer's start and its
    Done and that tick still stands (one sitting, one tick). If the Mac sleeps or Clew is not running at the end, the block decides
    when Clew runs again, still for its own day, even after 4 a.m.; a block ending at
    exactly 4:00 belongs to the day that ends then.
  - **Undo:** right-click a block that ticked › **Not finished** (or Undo, which takes
    back the task's latest tick today, as the row's undo does); the block stays, quieter, and does not tick again. **Changing a block's end**
    (move, resize) undoes its tick and lets it decide again, also after Not finished.
    **Removing** a block that ticked also undoes its tick (the tick belongs to the
    block); ticks made by hand are never touched. **Rounds:** once a counted goal's next
    round has started, a block whose tick came before that
    keeps the tick: it can still be removed (tick kept) but not moved or un-finished.
    **Earlier days:** a tick made for an earlier day (the Mac was asleep past 4 a.m.)
    shows one line per task above the list, "Ticked for yesterday: Write intro · Not
    finished" (or "for Friday"), until dismissed or the next rollover. Its Not finished
    undoes all of that task's ticks made that way, and is left out when the rule above
    keeps them. A goal whose total was reached that way shows its congratulation and
    choices on Today (*changed* 2026-11-15: on its row in Goals & Later).
  - Blocks are **not focus time**: only the focus timer and time added by hand are
    recorded. A focus timer can run on a task with a block.
  - **Leaving Today:** whenever a task is no longer on Today's list, for any reason but
    the rollover (moved to Later, deleted, edited or un-ticked off it), its blocks are
    removed for good (blocks not ended never tick; ticks already made stay). If it comes back the
    same day, it comes back without blocks. Blocks belong to their day: at 4 a.m. the
    timeline starts empty and an unfinished task rolls forward as usual, without its
    block. The rollover is not leaving Today: a block that ended the evening before still
    decides.
  - **Start alert:** "Write intro · Now until 10:30" when a block starts (no buttons,
    like the focus timer's). Settings › General › Day timeline › "Block alerts" (the
    start alert, and a slot block's "Done?"; renamed from "Alert when a block starts"
    when slots arrived; default on; *changed* while building: Settings has no Notifications pane,
    and a menu bar list cannot be opened from a notification). None
    for a block placed after its start or a task that needs nothing (done today, not a
    counted goal; a goal: total reached). Notification permission
    is asked when the first block is placed (if this is on); if it is denied, Settings
    says so.
  - **A repeating task's time slot** (*user*, 2026-11-10). A habit or a counted goal
    (*changed* 2026-11-15: habits only) can have a slot, set in Add and Edit: "On the timeline: at 8:00 for 60 min" (a
    checkbox, then "at [time] for [length]" indented under it; the start is one time
    field in quarter hours (see "Times on the timeline"), *changed* after use 2026-11-18:
    it was an hour menu and a minutes menu;
    a start on a quarter hour of the wall clock, a length of 15, 30, 45, 60, 90 or 120
    minutes; off by default). Clew then places that block by itself.
    - **When:** a slot block is placed when the task has a slot, is on Today and still
      needs something (a habit not done today; a goal not reached, even after a +1
      today), the timeline is on, the
      slot's **start is still ahead**, and the task has had **no block today** (live or
      removed). Clew checks at the day's start, whenever it runs, and right after the
      slot is saved, so a slot set at 7:00 for 8:00 appears today. A Mac opened at 8:30
      for an 8–9 slot gets no block that day; the task stays in the list (*user*).
      Blocks of earlier days decide first. On a day the task is not due (a weekday not
      chosen, a weekly target met) there is none.
    - **It never ticks by itself** (*user*: a slot that ticked daily would fill the
      heatmap and active days with no action). Otherwise it is a block like any other;
      where a hand block would tick at its end, a slot block **asks** instead (where a
      hand block would skip or be covered, it does so quietly): it shows "Done?", a
      notification "Done with Write intro?" offers **Done** (or **+1**), and right-click
      › Done / +1 works as on any block. Done is a hand tick that answers the block for
      good (undoing it leaves the block quiet; Not finished is not offered). Any hand
      tick made after it asks answers it the same way (a goal: the first one no other
      block used), and its notification is withdrawn. Unanswered,
      the task stays undone that day and nothing is counted; **the question ends at the
      rollover** (the notification is withdrawn, nothing is ticked late). While the
      timeline is off, slot blocks neither alert nor ask; one that ended meanwhile shows
      "Done?" when the timeline is back on, without a notification. The start alert and "Done?"
      share one switch: Settings › General › Day timeline › "Block alerts". A focus
      timer's Done adds nothing when the task got a block's tick or an answer to a slot
      block while the timer ran, and that tick still stands. Blocks placed by hand keep ticking at their end.
    - **Direct changes are for today only** (*user*): moving, resizing, removing it or
      dragging it back to the list changes today's block; tomorrow it is at the slot
      again. A block removed today does not come back today.
    - **The repeating slot changes only in Edit** (*user*). A change applies to today's
      block too if that block is untouched (not moved, resized or removed by hand) and
      has not started: it moves to the new slot, or is removed if the new slot has
      already started (nothing ticks). Turning the slot off removes an untouched block
      that has not started. Otherwise the change starts tomorrow.
    - **Time:** the slot is wall-clock time in the current zone. On a DST day a time
      that does not exist moves to the next quarter hour, a time that occurs twice is
      the first one, and the length is real minutes. A slot is cut at 4 a.m., like a
      dropped block. Once-tasks and links have no slot. Notification permission is asked
      when a slot is saved.
  - **A goal that reaches its total on the timeline goes back to the list** (*user*,
    2026-11-10, for every block): its row there shows the congratulation and Next round /
    Raise target / Done; its block stays on the timeline, done. The row stays in the list
    (after Next round or Raise target too, so nothing moves under the pointer) until it
    is placed again, and cannot be placed while the goal is reached.
  - **Calendar events (step 2)** show on the timeline as **read-only** blocks (*user*,
    2026-11-11: a thin stripe in the calendar's colour, a very light fill, the title in
    secondary text; they sit side by side with overlapping task blocks): title and time,
    nothing to click, never ticked, never counted,
    never alerted by Clew (Calendar has its own alerts). All-day events sit as a thin
    line at the top. Declined events are hidden. Clew reads **every calendar in macOS
    Calendar** (Google, iCloud, Exchange too, once added in System Settings › Internet
    Accounts); Settings › Calendar lists them with checkboxes, and Clew remembers only
    the ones unticked, so a new calendar shows by default. Clew **never writes to a
    calendar**, and events are read live: never saved, exported or sent anywhere.
    Access is asked only when "Show your calendar" on the timeline (or in Settings) is
    clicked; without it the timeline works with tasks alone. "Show your calendar" sits at
    the top of the timeline card until used or closed with ×; Settings › Calendar turns
    events on or off and lists the calendars by account. If macOS does not allow access,
    the timeline and Settings say so, with a way to the privacy settings.
  - **Steps:** (1) the timeline with task blocks, ticks and start alerts; (2) calendar
    events.
- Weeks start on **Monday**; "N× per week" items reset then.
- A counted goal's step is always **+1** per click.
- The rating row is offered **every time**, and is always skippable.
- Ratings are 5 points (rough … great), shown after a tick and on hover; Settings has
  a sidebar: General, Summaries, Progress, Data (2026-11-09; more sections since, the
  last one About, 2026-11-13).
- "Still want this?" lives only in the Later picker (*changed* 2026-11-15: removed
  with the picker); untouched = not saved, edited,
  moved to Later or kept for 42 days. Rating dots are built off by default, as a
  Settings switch (2026-11-09).
- Clicking a row opens its details; the link mark, not the title, opens a link.
  Goal bars align in one column. Rows can be dragged to reorder (2026-11-08, after use).
- Reminders fire on every day the item is on Today until done, once per day; "Later"
  moves a once-item or link to the Later pile (*changed* 2026-11-15: fires in either
  list; the Later button is removed); "Open" appears only for links
  (2026-11-08, v1b).
- Counted goals have rounds; reaching the total stops counting until the user picks
  next round, a higher target, or done (2026-11-08, after first use).
- A pasted link goes to Today by default, not Later; `↗` is replaced by a clickable
  title with a link mark (2026-11-08, after first use).
- Pasted links get their page title fetched (2026-11-08, after first use); this is
  then the app's only internet use (the v1.1 extension connection stays on this Mac;
  the update check, off by default, was added 2026-11-13).
- The menu bar title is an icon plus `done/total`, not the word "Clew" (2026-11-08, v1a).
- A counted goal's undo is a small `−` beside its count, shown only after a `+1` today;
  it removes the last `+1`. It sits apart from the circle so rapid ticks can't hit it
  (2026-11-08, v1a).
- Summary defaults: **9:00** and **21:00**, off until switched on.

## Open question

None currently open.

Decided 2026-11-11: a global shortcut opens the list; the default is ⌘. (Command-Period),
changeable in Settings › General.

## Tech

Swift 6, SwiftUI, macOS 14+, XcodeGen (`project.yml`), GRDB. Unit tests in a
framework target so they run without launching the app. Copy
`install-local.sh` and `LoginItem.swift` from Tact, minus its Accessibility
signing step. App Sandbox stays **on**: Clew needs no Accessibility permission. The
day timeline's events (v1.2) need the sandbox's Calendars entitlement
(`com.apple.security.personal-information.calendars`), an
`NSCalendarsFullAccessUsageDescription`, and full access: macOS 14 offers only full or
write-only access, no read-only, so the prompt text says Clew only reads.
