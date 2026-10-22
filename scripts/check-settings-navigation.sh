#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${HAPPY_LULU_SKIP_BUILD:-0}" != "1" ]]; then
  swift build --build-system native --product HappyLulu >/dev/null
fi
build_dir="$(swift build --build-system native --show-bin-path)"
frameworks="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-settings-navigation.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/NavigationProbe.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$probe_dir/data"
cp Resources/HappyLuluBrand.png "$app/Contents/Resources/"
cp -R Resources/OwlStates "$app/Contents/Resources/"
python3 - "${HAPPY_LULU_PROBE_APPEARANCE_SOURCE:-Sources/AfterSix/AppearanceModel.swift}" "$probe_dir/AppearanceModel.swift" "$app/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys, uuid
source = pathlib.Path(sys.argv[1]).read_text()
needle = 'static let shared = AppearanceModel()'
assert source.count(needle) == 1
# Only redirect the shared instance's storage and source icon; production view/model behavior is unchanged.
replacement = '''static let shared = AppearanceModel(store: AppearanceStore(rootDirectory: URL(fileURLWithPath: CommandLine.arguments[1]), bundleIdentifier: Bundle.main.bundleIdentifier!), originalIcon: NSImage(contentsOfFile: CommandLine.arguments[2])!)'''
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
with pathlib.Path(sys.argv[3]).open('wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='local.happylulu.navigation-probe.' + uuid.uuid4().hex,
        CFBundleExecutable='NavigationProbe', CFBundleName='NavigationProbe', CFBundlePackageType='APPL',
        LSUIElement=True, HappyLuluUpdateServiceEnabled=False), stream)
PY
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$PWD/.build/settings-navigation-module-cache" \
  -I "$build_dir/Modules" -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
  Sources/AfterSix/AppLanguage.swift Sources/AfterSix/AppModel.swift Sources/AfterSix/AppUpdater.swift \
  Sources/AfterSix/LuluBrand.swift \
  Sources/AfterSix/CalendarSyncModel.swift Sources/AfterSix/HalfDayCalendarReader.swift \
  Sources/AfterSix/DefaultFeatureAdapter.swift Sources/AfterSix/PluginManagerModel.swift \
  Sources/AfterSix/BundledPlugins.swift Sources/AfterSix/FeatureCalendarModel.swift \
  Sources/AfterSix/PluginSettingsView.swift "${HAPPY_LULU_PROBE_SETTINGS_SOURCE:-Sources/AfterSix/SettingsView.swift}" \
  Sources/AfterSix/AppearanceSettingsView.swift Sources/AfterSix/AttendanceCalendarView.swift \
  Sources/AfterSix/AttendanceControlsView.swift Sources/AfterSix/TodayDayTypeView.swift \
  Sources/AfterSix/FeatureCalendarView.swift Sources/AfterSix/CalendarWorkspaceView.swift \
  Sources/AfterSix/CalendarSyncSettingsView.swift "$probe_dir/AppearanceModel.swift" Tests/SettingsNavigationProbe/main.swift \
  "$build_dir"/AppPluginCore.build/*.swift.o "$build_dir"/AppPluginHost.build/*.swift.o \
  "$build_dir"/AfterSixCore.build/*.swift.o "$build_dir"/CalendarSyncServices.build/*.swift.o \
  "$build_dir"/CalendarSyncCore.build/*.swift.o \
  -framework AppKit -framework SwiftUI -framework CoreImage -framework Security \
  -framework EventKit -framework ServiceManagement -framework Sparkle -lsqlite3 \
  -o "$app/Contents/MacOS/NavigationProbe"
status=0
"$app/Contents/MacOS/NavigationProbe" "$probe_dir/data" "$PWD/Resources/HappyLuluIcon.png" || status=$?
if [[ -n "${HAPPY_LULU_NAVIGATION_EVIDENCE:-}" ]]; then
  mkdir -p "$HAPPY_LULU_NAVIGATION_EVIDENCE"
  cp "$probe_dir/data/"*.png "$HAPPY_LULU_NAVIGATION_EVIDENCE/"
fi
exit "$status"
