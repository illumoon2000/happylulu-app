#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product HappyLulu >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-vacation-eve.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/VacationEveProbe.app"
mkdir -p "$app/Contents/MacOS"
python3 - "$app/Contents/Info.plist" <<'PLIST'
import plistlib, sys, uuid
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='test.happylulu.vacation-eve.' + uuid.uuid4().hex,
        CFBundleExecutable='VacationEveProbe', CFBundlePackageType='APPL', LSUIElement=True), stream)
PLIST
swiftc -parse-as-library -swift-version 6 -I "$build_dir/Modules" \
  Sources/AfterSix/AppLanguage.swift Sources/AfterSix/AppModel.swift \
  Sources/AfterSix/CalendarSyncModel.swift Sources/AfterSix/HalfDayCalendarReader.swift \
  Sources/AfterSix/DefaultFeatureAdapter.swift Sources/AfterSix/PluginManagerModel.swift \
  Sources/AfterSix/BundledPlugins.swift Sources/AfterSix/FeatureCalendarModel.swift \
  Sources/AfterSix/PluginSettingsView.swift Tests/VacationEveProbe/main.swift \
  "$build_dir"/AppPluginCore.build/*.swift.o "$build_dir"/AppPluginHost.build/*.swift.o \
  "$build_dir"/AfterSixCore.build/*.swift.o "$build_dir"/CalendarSyncServices.build/*.swift.o \
  "$build_dir"/CalendarSyncCore.build/*.swift.o \
  -framework AppKit -framework Security -framework EventKit -framework ServiceManagement -lsqlite3 \
  -o "$app/Contents/MacOS/VacationEveProbe"
"$app/Contents/MacOS/VacationEveProbe" "$probe_dir/data"
