#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-write-checks.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
# Foundation-only checks: no dependency resolution, app launch, account or network.
swiftc -parse-as-library -swift-version 6 -module-cache-path "$probe_dir/cache" \
  -emit-module -emit-library -module-name DaouOfficeWritePlugin \
  Sources/DaouOfficeWritePlugin/*.swift \
  -emit-module-path "$probe_dir/DaouOfficeWritePlugin.swiftmodule" \
  -o "$probe_dir/libDaouOfficeWritePlugin.dylib"
swiftc -parse-as-library -swift-version 6 -module-cache-path "$probe_dir/cache" \
  -I "$probe_dir" -L "$probe_dir" -lDaouOfficeWritePlugin \
  -Xlinker -rpath -Xlinker "$probe_dir" \
  Tests/DaouOfficeWriteChecks/*.swift -o "$probe_dir/check"
"$probe_dir/check"
