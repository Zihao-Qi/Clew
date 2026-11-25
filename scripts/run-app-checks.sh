#!/bin/bash
# Runs the app's debug checks (in-memory data, no network, no real preferences):
# CLEW_AI_CHECK, CLEW_NOTES_TEST, CLEW_STEPS_TEST. Each must exit 0 within its time.
# They used to run only on the developer's Mac (2026-11-22 review of past errors).
#   scripts/run-app-checks.sh [--only CLEW_NOTES_TEST] [path/to/Clew]
# Use it for single checks too, never the binary by hand: it refuses an app older than
# the sources (a failed build leaves the last one in place; 2026-11-24 an older app ran
# a check it lacked as the real Clew).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - "$@" <<'PY'
import os
import pathlib
import subprocess
import sys

args = sys.argv[1:]
only = args[args.index("--only") + 1] if "--only" in args else ""
rest = [a for i, a in enumerate(args) if a != "--only" and (i == 0 or args[i - 1] != "--only")]
binary = rest[0] if rest else "DerivedData/Build/Products/Debug/Clew.app/Contents/MacOS/Clew"
if not os.path.exists(binary):
    sys.exit(f"FAIL: no app at {binary}: build it first")
sources = [p for d in ("App", "Sources", "Tests/ClewAppChecks") for p in pathlib.Path(d).rglob("*.swift")]
newer = [p for p in sources if p.stat().st_mtime > os.path.getmtime(binary)]
if newer:
    sys.exit(f"FAIL: the app is older than {newer[0]} (and {len(newer) - 1} more): build it first (did the build fail?)")
# A Release binary ignores the DEBUG-only switches and would start normally.
with open(binary, "rb") as f:
    if b"CLEW_NOTES_TEST" not in f.read():
        sys.exit("FAIL: refusing to launch a binary without the Debug checks")

CHECKS = [("CLEW_AI_CHECK", 60), ("CLEW_NOTES_TEST", 60), ("CLEW_STEPS_TEST", 150)]
if only:
    CHECKS = [c for c in CHECKS if c[0] == only]
    if not CHECKS:
        sys.exit(f"FAIL: no check named {only}")
# Only the one switch: an inherited CLEW_* variable must not turn this into another run.
base = {k: v for k, v in os.environ.items() if not k.startswith("CLEW_")}


def run(check: str, seconds: int) -> tuple[bool, str]:
    try:
        result = subprocess.run([binary], env={**base, check: "1"}, timeout=seconds, capture_output=True, text=True)
    except subprocess.TimeoutExpired as e:
        def text(x):
            return x.decode(errors="replace") if isinstance(x, bytes) else (x or "")
        out = text(e.stdout).splitlines()[-40:] + text(e.stderr).splitlines()[-20:]
        return False, "\n".join(out) + f"\nFAIL: {check} exceeded {seconds} seconds"
    lines = result.stdout.splitlines()
    passes = sum(l.startswith("PASS") for l in lines)
    ok = result.returncode == 0 and passes > 0
    shown = [l for l in lines if not l.startswith("PASS")]
    report = "\n".join(shown) if ok else "\n".join(shown[-40:] + result.stderr.splitlines()[-20:])
    return ok, f"{report}\n{passes} passed, exit {result.returncode}"


failed = []
for check, seconds in CHECKS:
    print(f"== {check}", flush=True)
    ok, report = run(check, seconds)
    # The Steps check clicks and drags in a real window, so another window taking the
    # front or a slow runner can trip it: it runs once more, and both reports show. A
    # real bug fails twice.
    if not ok and check == "CLEW_STEPS_TEST":
        print(report + "\n(failed once: running it again)", flush=True)
        ok, report = run(check, seconds)
    print(report, flush=True)
    if not ok:
        failed.append(check)
sys.exit(f"FAIL: {', '.join(failed)}" if failed else 0)
PY
