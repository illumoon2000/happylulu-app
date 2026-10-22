#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${HAPPY_LULU_SKIP_BUILD:-0}" != "1" ]]; then
  swift build --build-system native --product HappyLulu >/dev/null
fi
build_dir="$(swift build --build-system native --show-bin-path)"
frameworks="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-design-render.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/DesignProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$probe_dir/data"
cp Resources/HappyLuluBrand.png "$app/Contents/Resources/"
cp -R Resources/OwlStates "$app/Contents/Resources/"
python3 - Sources/AfterSix/TodayDayTypeView.swift "$probe_dir/TodayDayTypeView.swift" "${HAPPY_LULU_RENDER_EXPANDED:-0}" <<'PY2'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if sys.argv[3] == '1':
    needle = '@DayTypeState private var expanded = false'
    assert source.count(needle) == 1
    source = source.replace(needle, '@DayTypeState private var expanded = true')
pathlib.Path(sys.argv[2]).write_text(source)
PY2
python3 - Sources/AfterSix/AppearanceModel.swift "$probe_dir/AppearanceModel.swift" "$app/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys, uuid
source = pathlib.Path(sys.argv[1]).read_text()
needle = 'static let shared = AppearanceModel()'
assert source.count(needle) == 1
replacement = '''static let shared = AppearanceModel(store: AppearanceStore(rootDirectory: URL(fileURLWithPath: CommandLine.arguments[1]), bundleIdentifier: Bundle.main.bundleIdentifier!), originalIcon: NSImage(contentsOfFile: CommandLine.arguments[2])!)'''
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
with pathlib.Path(sys.argv[3]).open('wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='local.happylulu.design-probe.' + uuid.uuid4().hex,
        CFBundleExecutable='DesignProbe', CFBundleName='DesignProbe', CFBundlePackageType='APPL',
        LSUIElement=True, HappyLuluUpdateServiceEnabled=False), stream)
PY
sources=()
for source in Sources/AfterSix/*.swift; do
  case "$source" in */main.swift|*/AppearanceModel.swift|*/TodayDayTypeView.swift) continue ;; esac
  sources+=("$source")
done
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  -I "$build_dir/Modules" -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  "${sources[@]}" "$probe_dir/AppearanceModel.swift" "$probe_dir/TodayDayTypeView.swift" Tests/DesignRenderProbe/main.swift \
  "$build_dir"/AppPluginCore.build/*.swift.o "$build_dir"/AppPluginHost.build/*.swift.o \
  "$build_dir"/AfterSixCore.build/*.swift.o "$build_dir"/CalendarSyncServices.build/*.swift.o \
  "$build_dir"/CalendarSyncCore.build/*.swift.o \
  -framework AppKit -framework SwiftUI -framework CoreImage -framework Security \
  -framework EventKit -framework ServiceManagement -framework Sparkle -lsqlite3 \
  -o "$app/Contents/MacOS/DesignProbe"
"$app/Contents/MacOS/DesignProbe" "$probe_dir/data" "$PWD/Resources/HappyLuluIcon.png" \
  "${HAPPY_LULU_RENDER_OUTPUT:-$PWD/.build/design-validation/render${HAPPY_LULU_RENDER_EXPANDED:+-expanded}}"
