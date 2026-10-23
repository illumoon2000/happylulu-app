#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-material-policy.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
# Compile the actual view policy without app models, production stores, external services or packaging.
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$probe_dir/module-cache" \
  Sources/AfterSix/LuluMaterials.swift Tests/MaterialPolicyProbe/main.swift \
  -framework AppKit -framework SwiftUI -o "$probe_dir/check"
"$probe_dir/check"
