#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/Policy.swift Tests/PolicyTests.swift -o build/policy-tests
build/policy-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/Policy.swift Sources/AutomationLifecycle.swift Tests/LifecycleTests.swift -o build/lifecycle-tests
build/lifecycle-tests
if [[ -x "build/Panel Off.app/Contents/MacOS/PanelOff" ]]; then
  "build/Panel Off.app/Contents/MacOS/PanelOff" --startup-check
  # Exercise real CLI enumeration without invoking AppKit or changing a display.
  "build/Panel Off.app/Contents/MacOS/PanelOff" --status > build/status-smoke.txt
  printf 'Read-only display helper smoke check passed\n'
fi
