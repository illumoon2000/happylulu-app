#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product HappyLulu >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-appearance.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/AppearanceProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/HappyLuluBrand.png "$app/Contents/Resources/"
cp -R Resources/OwlStates "$app/Contents/Resources/"
python3 - "$app/Contents/Info.plist" <<'PY2'
import pathlib, plistlib, sys
with pathlib.Path(sys.argv[1]).open('wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='test.happylulu.appearance-probe',
        CFBundleExecutable='AppearanceProbe', CFBundlePackageType='APPL', LSUIElement=True), stream)
PY2
swiftc -parse-as-library -swift-version 6 -I "$build_dir/Modules" \
  Sources/AfterSix/AppLanguage.swift Sources/AfterSix/LuluBrand.swift Sources/AfterSix/AppearanceModel.swift Tests/AppearanceModelProbe/main.swift \
  "$build_dir"/AfterSixCore.build/*.swift.o -framework AppKit -framework CoreImage \
  -o "$app/Contents/MacOS/AppearanceProbe"
"$app/Contents/MacOS/AppearanceProbe" "$probe_dir/data" "$PWD/Resources/HappyLuluIcon.png"
