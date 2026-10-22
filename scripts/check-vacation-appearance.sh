#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" -gt 1 ]]; then
  echo "Usage: $0 [OUTPUT_DIRECTORY]" >&2
  exit 2
fi
output="${1:-${HAPPY_LULU_RENDER_OUTPUT:-$PWD/.build/vacation-validation/appearance}}"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-vacation-appearance.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/VacationProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$probe_dir/modules"
cp Resources/HappyLuluBrand.png "$app/Contents/Resources/"
cp -R Resources/OwlStates "$app/Contents/Resources/"
python3 - "$app/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys, uuid
with pathlib.Path(sys.argv[1]).open('wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='local.happylulu.vacation-probe.' + uuid.uuid4().hex,
        CFBundleExecutable='VacationProbe', CFBundleName='VacationProbe', CFBundlePackageType='APPL',
        LSUIElement=True), stream)
PY
# This fixture compiles only the presentation and core; it never starts the real app or its services.
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$probe_dir/module-cache" -emit-module -emit-library -module-name AfterSixCore \
  -emit-module-path "$probe_dir/modules/AfterSixCore.swiftmodule" \
  Sources/AfterSixCore/*.swift -o "$probe_dir/modules/libAfterSixCore.dylib"
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$probe_dir/module-cache" -I "$probe_dir/modules" -L "$probe_dir/modules" \
  -lAfterSixCore -Xlinker -rpath -Xlinker "$probe_dir/modules" \
  Sources/AfterSix/LuluBrand.swift Tests/VacationAppearanceProbe/main.swift \
  -framework AppKit -o "$app/Contents/MacOS/VacationProbe"
"$app/Contents/MacOS/VacationProbe" "$output"
