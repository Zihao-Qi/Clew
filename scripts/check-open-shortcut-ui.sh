#!/bin/bash
# Run only the debug fixture: in-memory database, no notifications or permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
binary="${1:-DerivedData/Build/Products/Debug/Clew.app/Contents/MacOS/Clew}"
python3 -I - "$binary" <<'PY'
import os
import subprocess
import sys
# A Release binary ignores the DEBUG-only switch and would start normally.
# Refuse it before launch, even if the caller supplies the wrong executable.
with open(sys.argv[1], "rb") as binary:
    if b"CLEW_SHORTCUT_SMOKE" not in binary.read():
        sys.exit("FAIL: refusing to launch a binary without the Debug smoke fixture")
try:
    result = subprocess.run([sys.argv[1]], env={**os.environ, "CLEW_SHORTCUT_SMOKE": "1"}, timeout=30)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit("FAIL: shortcut UI fixture exceeded 30 seconds")
PY
