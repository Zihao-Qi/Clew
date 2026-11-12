#!/bin/bash
# Compile the actual app adapter, which SwiftPM's Core tests do not include.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target ClewCore
bin="$(swift build --show-bin-path)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Xcode's SwiftPM driver emits one object per module; native SwiftPM emits
# individual objects. Support both without adding AppKit to a library target.
objects=()
for module in ClewCore ClewDomain; do
    if [[ -f "$bin/$module.o" ]]; then
        objects+=("$bin/$module.o")
    else
        objects+=("$bin/$module.build/"*.o)
    fi
done
for check in OpenShortcutObservationCheck OpenShortcutHandlerFailureCheck; do
    swiftc -swift-version 6 -parse-as-library -I "$bin" -I "$bin/Modules" \
        App/Clew/OpenShortcutHotkey.swift \
        "Tests/ClewAppChecks/$check.swift" \
        "${objects[@]}" -o "$scratch/$check"
    "$scratch/$check"
done
