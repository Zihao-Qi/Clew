#!/usr/bin/env python3
"""Mutation check for the app's debug checks (AGENTS.md rule 1 for App/Clew).

Each entry breaks one rule in the app on purpose, rebuilds the Debug app, runs the
named debug check and expects a FAIL. "SURVIVED" means no check noticed: add or fix a
check. The source is always restored and the app rebuilt at the end. Each mutation
rebuilds the app (about a minute), so this runs locally, not in CI; `--patterns` is
fast and only checks that every entry still matches its source once.

  python3 -I scripts/mutation-check-app.py .                 # all
  python3 -I scripts/mutation-check-app.py . --only Notes    # names containing "Notes"
  python3 -I scripts/mutation-check-app.py . --patterns
"""
import pathlib
import signal
import subprocess
import sys

A = "App/Clew/"
AI, NOTES, STEPS = "CLEW_AI_CHECK", "CLEW_NOTES_TEST", "CLEW_STEPS_TEST"

M = [
    # Memory (SPEC "Memory")
    ("AI record while not ready", A + "AIModel.swift",
     "                tick: UUID? = nil) {\n        guard isReady else { return }\n", "                tick: UUID? = nil) {\n", AI),
    ("AI fetched title recorded", A + "AppModel.swift", "typed: task.titleOrigin == .typed,", "typed: true,", AI),
    ("AI off keeps record", A + "AIModel.swift", "        jobGeneration += 1\n        memory.clearActivity()\n",
     "        jobGeneration += 1\n", AI),
    ("AI note not kept", A + "AIModel.swift", "        case .success(let notes): memory.replace(notes)\n",
     "        case .success: break\n", AI),
    ("AI answer ignores changes", A + "AIModel.swift",
     "guard isReady, memory.notes.first(where: { $0.id == shown.id }) == shown else { return }",
     "guard isReady else { return }", AI),
    ("AI noticed without ready", A + "AppModel.swift",
     "var noticedShown: [Note] { ai?.isReady == true ? noticed : [] }", "var noticedShown: [Note] { noticed }", AI),
    ("AI suggest on a done task", A + "StepSuggestions.swift", "return canAddStep(row) && !row.isDone",
     "return canAddStep(row)", AI),
    # Steps and the timeline
    ("Steps shown while dragged", A + "TodayListView.swift",
     "if ((steps != nil && model.isUnfolded(row.id)) || adding) && dragging != row.id {",
     "if (steps != nil && model.isUnfolded(row.id)) || adding {", STEPS),
    ("Steps full height while folded", A + "TodayListView.swift",
     "                    if showsSteps, let from = ids.firstIndex(of: row.id), let own = ownHeights[row.id],",
     "                    if false, let from = ids.firstIndex(of: row.id), let own = ownHeights[row.id],", STEPS),
    ("Steps old grip on short blocks", A + "DayTimelineView.swift",
     "height < 29 ? (max(3, height / 4), 0) : (8, 4)", "(8, 4)", STEPS),
    ("Steps placed steps hidden", A + "StepViews.swift",
     "        let entries = steps.entries\n        guard let held",
     "        let placed = model.timeline?.placedSteps ?? []\n        let entries = steps.entries.filter { !placed.contains($0.id) }\n        guard let held",
     STEPS),
    ("Steps task never leaves", A + "AppModel.swift",
     "let placed = day.placedItems.union(day.tasksWithAllStepsPlaced(steps))", "let placed = day.placedItems", STEPS),
    ("Steps done task refuses steps", A + "AppModel.swift",
     "(row.progressAmount == 0 || (row.isDone && row.progressAmount == row.todayAmount))",
     "!row.isDone && row.progressAmount == 0", STEPS),
    ("Steps rename ignores outside clicks", A + "StepViews.swift",
     "            .background(OutsideClickWatcher(onOutside: save))\n            // The step left the list",
     "            // The step left the list", STEPS),
    ("Steps empty title sent", A + "StepViews.swift", "if !trimmed.isEmpty, trimmed != step.title",
     "if trimmed != step.title", STEPS),
    # Notes (SPEC "Notes")
    ("Notes shift-return submits", A + "NoteBox.swift", "if (textView as? NoteTextView)?.shiftHeld == true {",
     "if false {", NOTES),
    ("Notes draft dropped on Esc", A + "NoteBox.swift", "    func close() {\n        keepDraft()\n",
     "    func close() {\n", NOTES),
    ("Notes draft not restored", A + "NoteBox.swift",
     "state.text = Self.defaults.string(forKey: Self.draftKey) ?? \"\"", "state.text = \"\"", NOTES),
    ("Notes focus ignored", A + "NotesModel.swift", "timer.phase == .focus, !timer.isOver(at: now)",
     "timer.phase == .focus, false", NOTES),
    ("Notes done block chosen", A + "NotesModel.swift", "            guard taskNeeds else { return false }\n", "", NOTES),
    ("Notes half goal skipped", A + "NotesModel.swift",
     "row.item.progress.target != nil ? !row.isGoalReached : !row.isDone", "!row.isDone", NOTES),
    ("Notes earliest start wins", A + "NotesModel.swift", "return (-b.block.start.timeIntervalSinceReferenceDate,",
     "return (b.block.start.timeIntervalSinceReferenceDate,", NOTES),
    ("Notes step before task", A + "NotesModel.swift", "b.block.stepId == nil ? 0 : 1", "b.block.stepId == nil ? 1 : 0",
     NOTES),
    ("Notes weekday a day too far", A + "NotesView.swift", "if days > 0, days <= 6 {", "if days > 0, days <= 7 {", NOTES),
    ("Notes box under the menu bar", A + "NoteBox.swift", "let top = visible.maxY - visible.height / 4",
     "let top = visible.maxY - 8", NOTES),
    ("Notes banner gone at once", A + "NoteBox.swift", "try? await Task.sleep(for: .seconds(2.0))",
     "try? await Task.sleep(for: .seconds(0.6))", NOTES),
    ("Notes banner stays long", A + "NoteBox.swift", "try? await Task.sleep(for: .seconds(2.0))",
     "try? await Task.sleep(for: .seconds(3.6))", NOTES),
    ("Notes sweep never settles", A + "NoteBox.swift",
     "withAnimation(.easeOut(duration: 0.25)) { state.settled = true }", "_ = 0", NOTES),
    ("Notes title bar safe area", A + "NoteBox.swift", "        host.safeAreaRegions = []\n", "", NOTES),
    ("Notes title bar separator", A + "NoteBox.swift", "        panel.titlebarSeparatorStyle = .none\n", "", NOTES),
    ("Notes banner not the box's size", A + "NoteBox.swift", "            banner.setFrame(frame, display: false)",
     "            banner.setFrame(NSRect(x: frame.minX, y: frame.maxY - max(frame.height, 64), width: frame.width, height: max(frame.height, 64)), display: false)",
     NOTES),
    ("Notes three lines", A + "NoteBox.swift", "focusRequest: state.focusRequest, maxLines: 4,",
     "focusRequest: state.focusRequest, maxLines: 3,", NOTES),
    ("Notes draft opens short", A + "NoteBox.swift", "        place(panel, height: 50)\n        fitNow(panel)\n",
     "        place(panel, height: 50)\n", NOTES),
    ("Notes text under the title bar", A + "NoteBox.swift", "almost hidden).\n        scroll.automaticallyAdjustsContentInsets = false\n",
     "almost hidden).\n", NOTES),
    ("Notes swept text a SwiftUI label", A + "NoteBox.swift", "NoteTextShown(text: state.savedText, scrolledBy: state.savedScroll, maxLines: 4)",
     "Text(verbatim: state.savedText).lineLimit(4)", NOTES),
    ("Notes swept text centred", A + "NoteBox.swift", "alignment: settled ? .leading : .topLeading)",
     "alignment: .leading)", NOTES),
    ("Notes swept text shows the start", A + "NoteBox.swift",
     "state.savedScroll = Self.scrollView(in: panel?.contentView)?.contentView.bounds.minY ?? 0", "state.savedScroll = 0", NOTES),
    ("Notes swept text always at the end", A + "NoteBox.swift", "y: min(max(0, scrolledBy), most)", "y: most", NOTES),
    ("Notes swept one line shorter", A + "NoteBox.swift",
     "let height = max(min(used, line * CGFloat(maxLines)).rounded(.up), 22)",
     "let height = min(used, line * CGFloat(maxLines)).rounded(.up)", NOTES),
    ("Notes saved in another size", A + "NoteBox.swift", "        .font(Font(NoteBox.textFont))\n        .padding(.horizontal, 16)",
     "        .font(.body)\n        .padding(.horizontal, 16)", NOTES),
    ("Notes closed banner settles", A + "NoteBox.swift", "state.bannerShown == shown, state.banner != nil else",
     "state.bannerShown == shown else", NOTES),
    ("Notes focus runs while writing", A + "NoteBox.swift", "        pauseFocusForNote()\n", "", NOTES),
    ("Notes focus stays paused after", A + "NoteBox.swift", "        resumeFocusAfterNote()\n    }\n", "    }\n", NOTES),
    ("Notes paused focus resumed", A + "NoteBox.swift", "timer.phase == .focus,\n              !timer.isPaused, ",
     "timer.phase == .focus,\n              ", NOTES),
    ("Notes During gone in the sweep", A + "NoteBox.swift",
     "                                NoteDuringLine(title: context.title)\n                                    .debugFrame(\"sweptDuring\\(state.bannerShown)\")\n",
     "                                EmptyView()\n", NOTES),
    ("Notes band shrinks back", A + "NoteBox.swift", "                    .frame(width: geo.size.width * sweep)\n                    .opacity(settled ? 0 : 1)\n",
     "                    .frame(width: settled ? 3 : geo.size.width * sweep)\n", NOTES),
    ("Notes Saved bold", A + "NoteBox.swift", "Text(\"Saved\")   // not bold", "Text(\"Saved\").fontWeight(.semibold)   // not bold", NOTES),
    ("Notes break paused", A + "NoteBox.swift", "let timer = model.focus, timer.phase == .focus,", "let timer = model.focus,", NOTES),
    ("Notes expired focus paused", A + "NoteBox.swift", "!timer.isPaused, !timer.isOver(at: Date()) else", "!timer.isPaused else", NOTES),
    ("Notes another focus resumed", A + "NoteBox.swift",
     "guard let model, let timer = model.focus, timer.itemId == paused.item, timer.startedAt == paused.started,",
     "guard let model, let timer = model.focus,", NOTES),
    ("Notes band stays", A + "NoteBox.swift", "                    .frame(width: geo.size.width * sweep)\n                    .opacity(settled ? 0 : 1)\n",
     "                    .frame(width: geo.size.width * sweep)\n", NOTES),
    ("Notes no left bar", A + "NoteBox.swift", "                    .frame(width: 3)\n                    .opacity(settled ? 1 : 0)\n",
     "                    .frame(width: 3)\n                    .opacity(0)\n", NOTES),
    ("Notes quit leaves it paused", A + "NoteBox.swift", "        watchQuit()\n", "", NOTES),
    ("Next with one open task", A + "WhatNextPanel.swift", "&& focus == nil && whatNextOpenRows.count >= 2",
     "&& focus == nil && whatNextOpenRows.count >= 1", AI),
    ("Next during a focus", A + "WhatNextPanel.swift", "ai?.canSuggestSteps == true && focus == nil && whatNextOpenRows",
     "ai?.canSuggestSteps == true && whatNextOpenRows", AI),
    ("Next choose does nothing", A + "WhatNextPanel.swift", "        picks.swapAt(0, i)\n",
     "", AI),
    ("Next focus 10 min", A + "WhatNextPanel.swift", "model.startFocus(row, minutes: 25)",
     "model.startFocus(row, minutes: 10)", AI),
    ("Next other never", A + "WhatNextPanel.swift", "focus: true,\n                             other: pick.itemId != first)",
     "focus: true,\n                             other: false)", AI),
    ("Next title goes nowhere", A + "WhatNextPanel.swift", "        model.requestReveal(pick.itemId)\n",
     "", AI),
    ("Next dismissal forgotten", A + "WhatNextPanel.swift", "        if case .shown = state { model.ai?.recordNextDismissed() }\n",
     "", AI),
    ("Next cancel recorded", A + "WhatNextPanel.swift", "        if case .shown = state { model.ai?.recordNextDismissed() }",
     "        if true { model.ai?.recordNextDismissed() }", AI),
    ("Next ticked pick stays", A + "WhatNextPanel.swift", "            picks.removeAll { !open.contains($0.itemId) }\n",
     "", AI),
    ("Next asking never closes", A + "WhatNextPanel.swift", "            if !model.canAskWhatNext { close() }\n",
     "            break\n", AI),
    ("Next ticked while asking shown", A + "WhatNextPanel.swift", "let kept = picks.filter { open.contains($0.itemId) }",
     "let kept = picks", AI),
    ("Next ended sign-in closes", A + "WhatNextPanel.swift", "        case .idle, .signInEnded:\n            break",
     "        case .idle:\n            break\n        case .signInEnded:\n            close()", AI),
    ("Next focus through steps", A + "WhatNextPanel.swift", "$0.block.itemId == itemId && $0.block.stepId == nil }",
     "$0.block.itemId == itemId }", AI),
    ("Next fetched as typed", A + "WhatNextPanel.swift", "typed: row.item.titleOrigin == .typed,\n                                      kind: kind",
     "typed: true,\n                                      kind: kind", AI),
    ("Next focus keeps it open", A + "WhatNextPanel.swift", "guard ready, model.focus == nil else { return close() }",
     "guard ready else { return close() }", AI),
    ("Next highlight stays", A + "AppModel.swift", "try? await Task.sleep(for: .seconds(1))\n            if revealRequests == mine { highlighted = nil }",
     "try? await Task.sleep(for: .seconds(5))\n            if revealRequests == mine { highlighted = nil }", AI),
    ("Notes banner without task", A + "NoteBox.swift",
     "text = String(localized: \"Saved. Back to: \\(context.title)\\(context.detail)\")",
     "text = String(localized: \"Saved.\"); _ = context", NOTES),
]

repo = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ".")
binary = repo / "DerivedData/Build/Products/Debug/Clew.app/Contents/MacOS/Clew"


def build() -> bool:
    result = subprocess.run(["xcodebuild", "-project", "Clew.xcodeproj", "-scheme", "Clew", "-configuration", "Debug",
                             "-derivedDataPath", "DerivedData", "build"], cwd=repo, capture_output=True, text=True)
    return "BUILD SUCCEEDED" in result.stdout


def run(check: str) -> list[str]:
    """What noticed the mutation: FAIL lines, a crash or a hang. Empty: nothing did."""
    try:
        result = subprocess.run([str(binary)], env={"HOME": str(pathlib.Path.home()), check: "1"},
                                capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        return ["TIMEOUT"]
    fails = [l for l in result.stdout.splitlines() if l.startswith("FAIL")]
    if result.returncode != 0 and not fails:
        fails = [f"exit {result.returncode} (crashed or stopped)"]
    return fails


if "--patterns" in sys.argv:
    stale = [(name, (repo / path).read_text().count(old)) for name, path, old, _, _ in M
             if (repo / path).read_text().count(old) != 1]
    for name, count in stale:
        print(f"{name:40} PATTERN NOT UNIQUE ({count})")
    print(f"{len(M) - len(stale)} of {len(M)} patterns match once")
    sys.exit(1 if stale else 0)

# A SIGTERM restores the sources and rebuilds too, as Ctrl-C does.
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))

only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
survived = 0
# What fails before anything is broken (a check this Mac cannot pass today) is not a
# kill: only a failure the mutation adds counts.
baseline: dict[str, set[str]] = {}
try:
    if not build():
        sys.exit("FAIL: the unmutated app did not build")
    for check in sorted({m[4] for m in M if not only or only in m[0]}):
        baseline[check] = set(run(check))
        if baseline[check]:
            print(f"baseline {check}: {sorted(baseline[check])}", flush=True)
    for name, path, old, new, check in M:
        if only and only not in name:
            continue
        f = repo / path
        orig = f.read_text()
        if orig.count(old) != 1:
            print(f"{name:40} PATTERN NOT UNIQUE ({orig.count(old)})", flush=True)
            survived += 1
            continue
        try:
            f.write_text(orig.replace(old, new))
            if not build():
                print(f"{name:40} BUILD FAILED", flush=True)
                survived += 1
                continue
            fails = [f for f in run(check) if f not in baseline.get(check, set())]
            print(f"{name:40} {'KILLED' if fails else 'SURVIVED'}  {fails[:1]}", flush=True)
            survived += 0 if fails else 1
        finally:
            f.write_text(orig)
finally:
    print("rebuilding the unmutated app…", flush=True)
    if not build():
        print("FAIL: the unmutated app did not build", flush=True)
        survived += 1
sys.exit(1 if survived else 0)
