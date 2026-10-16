#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product HappyLulu >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-panel-focus.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
# Keep shared appearance initialization isolated while compiling the actual panel and model sources.
python3 - Sources/AfterSix/AppearanceModel.swift "$probe_dir/AppearanceModel.swift" "$probe_dir" <<'PY'
import json, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = 'static let shared = AppearanceModel()'
assert source.count(needle) == 1
replacement = ('static let shared = AppearanceModel(store: AppearanceStore(rootDirectory: '
    'URL(fileURLWithPath: ' + json.dumps(sys.argv[3]) + '), bundleIdentifier: "test.happylulu.panel-focus"), '
    'originalIcon: NSImage(size: NSSize(width: 16, height: 16)))')
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PY
# Offscreen CLI hosting exposes no AX button tree. Enter through the real beginEditing method;
# keep the panel body, focus observation, deferred save and click-away handling unchanged.
python3 - Sources/AfterSix/PanelView.swift "$probe_dir/PanelView.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = '.onAppear { model.refresh() }'
assert source.count(needle) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, '.onAppear { model.refresh(); beginEditing() }'))
PY
swiftc -parse-as-library -swift-version 6 -I "$build_dir/Modules" \
  Sources/AfterSix/AppLanguage.swift Sources/AfterSix/AppModel.swift \
  Sources/AfterSix/CalendarSyncModel.swift Sources/AfterSix/HalfDayCalendarReader.swift \
  Sources/AfterSix/DefaultFeatureAdapter.swift Sources/AfterSix/PluginManagerModel.swift \
  Sources/AfterSix/BundledPlugins.swift Sources/AfterSix/PluginSettingsView.swift \
  Sources/AfterSix/FeatureCalendarModel.swift Sources/AfterSix/TodayAgendaView.swift \
  Sources/AfterSix/TodayDayTypeView.swift Sources/AfterSix/ArrivalClockDigitField.swift \
  "$probe_dir/PanelView.swift" "$probe_dir/AppearanceModel.swift" Tests/PanelFocusProbe/main.swift \
  "$build_dir"/AppPluginCore.build/*.swift.o "$build_dir"/AppPluginHost.build/*.swift.o \
  "$build_dir"/AfterSixCore.build/*.swift.o "$build_dir"/CalendarSyncServices.build/*.swift.o \
  "$build_dir"/CalendarSyncCore.build/*.swift.o \
  -framework AppKit -framework SwiftUI -framework Security -framework EventKit -framework ServiceManagement -lsqlite3 \
  -o "$probe_dir/check"
for time_zone in UTC Asia/Seoul America/Los_Angeles; do
  case "$time_zone" in
    UTC) fixture_time_zone=Asia/Seoul ;;
    Asia/Seoul) fixture_time_zone=America/Los_Angeles ;;
    America/Los_Angeles) fixture_time_zone=UTC ;;
  esac
  TZ="$time_zone" "$probe_dir/check" "$probe_dir/$time_zone" "$fixture_time_zone"
done
