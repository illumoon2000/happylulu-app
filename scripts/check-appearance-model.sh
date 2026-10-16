#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product HappyLulu >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-appearance.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -parse-as-library -swift-version 6 -I "$build_dir/Modules" \
  Sources/AfterSix/AppLanguage.swift Sources/AfterSix/AppearanceModel.swift Tests/AppearanceModelProbe/main.swift \
  "$build_dir"/AfterSixCore.build/*.swift.o -framework AppKit -framework CoreImage \
  -o "$probe_dir/check"
"$probe_dir/check" "$probe_dir/data" "$PWD/Resources/HappyLuluIcon.png"
