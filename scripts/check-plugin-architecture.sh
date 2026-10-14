#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --product HappyLulu >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-plugin-architecture.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -parse-as-library -swift-version 6 -I "$build_dir/Modules" \
  Sources/AfterSix/AppLanguage.swift Sources/AfterSix/AppModel.swift \
  Sources/AfterSix/CalendarSyncModel.swift Sources/AfterSix/HalfDayCalendarReader.swift \
  Sources/AfterSix/DefaultFeatureAdapter.swift \
  Sources/AfterSix/PluginManagerModel.swift Sources/AfterSix/BundledPlugins.swift Sources/AfterSix/FeatureCalendarModel.swift \
  Sources/AfterSix/PluginSettingsView.swift Tests/PluginArchitectureProbe/main.swift \
  "$build_dir"/AppPluginCore.build/*.swift.o "$build_dir"/AppPluginHost.build/*.swift.o \
  "$build_dir"/AfterSixCore.build/*.swift.o "$build_dir"/CalendarSyncServices.build/*.swift.o \
  "$build_dir"/CalendarSyncCore.build/*.swift.o \
  -framework AppKit -framework Security -framework EventKit -framework ServiceManagement -lsqlite3 \
  -o "$probe_dir/check"
"$probe_dir/check" "$@"
