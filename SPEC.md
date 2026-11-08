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
 Clew  4/6                      ← menu bar title
 ─────────────────────────────────────
 ✓ Exercise
 ✓ Apply to 1 job
 ○ ML course      ███████░░░░░░  10/30  ↗
 ○ Watch later    ████████░░░░    2/3   ↗
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
   - *Repeating*: daily, chosen weekdays, or N times per week.
   - *Counted goal*: a total (e.g. 30 videos). Today's step is `+1` (or a
     set step). The bar shows lifetime progress; the item counts as done today
     once you've added at least one step.
3. **Links.** Any item can have a URL. `↗` opens it in the default browser.
4. **Done in one click.** Click `○` to mark it done (counted goals: +1). A 1–3 rating
   row then appears inline; it's optional and dismisses itself.
5. **Later pile.** Saving a link (paste into `+ add`, or choose "Later") puts it
   in a hidden pile. Its count is shown, its contents aren't. "Pick 1–3 for today"
   moves items onto the list. Items untouched for 6 weeks get a one-tap
   "still want this?". Saying no counts as a win.
6. **Gentle reminders** (optional, per item, off by default). One notification at
   a chosen time with **Open / Done / Later** actions. No repeats, no escalation.
7. **Day summaries** (each optional): morning "6 today", evening "5/6 done".
   Short, friendly, never a list of failures.
8. **Local data.** A SQLite database (GRDB) in Application Support. One-click JSON
   export. No account, no network.
9. **Launch at login** (`SMAppService`), toggled in a small Settings window.

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
- Browser extension import: YouTube Watch Later (list + watch %, verified feasible
  2026-11-08) and X bookmarks.
- AI recap and quick-start suggestion (Pi agent via a Clew/Dayflow MCP server).
- Sync with Dayflow (its local JSON API: `GET /api/day`, `PATCH /api/tasks/:id`).
- iPhone, iCloud sync, Obsidian export.

## Done means used

v1 is done when it has been **used on 5 of 7 days for two weeks**, not when its
tests pass. Clew records active days locally (a day with at least one tick) and
shows them only in Settings. Until that bar is met, the next work is fixing whatever
stopped daily use, not adding features.

## Open questions

1. Week start: Monday or Sunday? Does "3× per week" reset on that day?
2. Counted goals: is the default daily step always 1, or set per goal?
3. Should rating be asked every time, or only for counted goals and Later items?
4. Which hotkey, if any, opens the list?
5. Do the morning and evening summary times default to 9:00 and 21:00?

## Tech

Swift 6, SwiftUI, macOS 14+, XcodeGen (`project.yml`), GRDB. Unit tests in a
framework target so they run without launching the app. Copy
`install-local.sh` and `LoginItem.swift` from Tact, minus its Accessibility
signing step. App Sandbox stays **on**: Clew needs no Accessibility permission.
