#!/bin/bash
# Runs the app's debug checks (in-memory data, no network, no real preferences):
# CLEW_AI_CHECK, CLEW_NOTES_TEST, CLEW_STEPS_TEST. Each must exit 0 within its time.
# They used to run only on the developer's Mac (2026-11-22 review of past errors).
set -euo pipefail
cd "$(dirname "$0")/.."
binary="${1:-DerivedData/Build/Products/Debug/Clew.app/Contents/MacOS/Clew}"
python3 -I - "$binary" <<'PY'
import os
import subprocess
import sys

binary = sys.argv[1]
# A Release binary ignores the DEBUG-only switches and would start normally.
with open(binary, "rb") as f:
    if b"CLEW_NOTES_TEST" not in f.read():
        sys.exit("FAIL: refusing to launch a binary without the Debug checks")

CHECKS = [("CLEW_AI_CHECK", 60), ("CLEW_NOTES_TEST", 60), ("CLEW_STEPS_TEST", 150)]
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
    # Clicks and drags need Clew in front; if another window took it, try once more.
    if not ok and "Clew could not stay in front" in report:
        print(report + "\n(another app took the front: running it once more)", flush=True)
        ok, report = run(check, seconds)
    print(report, flush=True)
    if not ok:
        failed.append(check)
sys.exit(f"FAIL: {', '.join(failed)}" if failed else 0)
PY
