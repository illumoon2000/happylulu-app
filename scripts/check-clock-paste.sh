#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target AfterSixCore >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-clock-paste.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -parse-as-library -swift-version 6 -I "$build_dir/Modules" \
  Sources/AfterSix/ArrivalClockDigitField.swift Tests/ClockPasteProbe/main.swift \
  "$build_dir"/AfterSixCore.build/*.swift.o \
  -framework AppKit -framework SwiftUI -o "$probe_dir/check"
"$probe_dir/check"
