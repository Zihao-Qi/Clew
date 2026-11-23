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

failed = []
for check, seconds in [("CLEW_AI_CHECK", 60), ("CLEW_NOTES_TEST", 60), ("CLEW_STEPS_TEST", 120)]:
    print(f"== {check}", flush=True)
    try:
        result = subprocess.run([binary], env={**os.environ, check: "1"}, timeout=seconds,
                                capture_output=True, text=True)
        lines = [l for l in result.stdout.splitlines() if l.startswith(("PASS", "FAIL", "ALL", "Clew could not"))]
        print("\n".join(l for l in lines if not l.startswith("PASS")) or "(no failures)")
        passes = sum(l.startswith("PASS") for l in lines)
        print(f"{passes} passed, exit {result.returncode}", flush=True)
        if result.returncode != 0 or passes == 0:
            failed.append(check)
    except subprocess.TimeoutExpired:
        print(f"FAIL: {check} exceeded {seconds} seconds", flush=True)
        failed.append(check)
sys.exit(f"FAIL: {', '.join(failed)}" if failed else 0)
PY
