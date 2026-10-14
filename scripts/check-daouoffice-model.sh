#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --target DaouOfficeIntegration >/dev/null
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-plugin-model.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -swift-version 6 -I "$build_dir/Modules" \
  Sources/DaouOfficeIntegration/DaouOfficePluginModel.swift Sources/DaouOfficeIntegration/DaouOfficePluginSettingsView.swift \
  Sources/AfterSix/AppLanguage.swift Tests/DaouOfficeModelProbe/main.swift \
  "$build_dir"/AppPluginHost.build/*.swift.o "$build_dir"/AppPluginCore.build/*.swift.o "$build_dir"/DaouOfficePlugin.build/*.swift.o \
  "$build_dir"/CalendarSyncServices.build/*.swift.o "$build_dir"/CalendarSyncCore.build/*.swift.o \
  "$build_dir"/AfterSixCore.build/*.swift.o \
  -framework AppKit -framework Security -framework EventKit -lsqlite3 -o "$probe_dir/check"
if [[ "${1:-}" == "--show-ui" || "${1:-}" == "--show-captcha-ui" ]]; then
  app_dir="$(pwd)/.build/DaouOfficePluginPreview.app"
  mkdir -p "$app_dir/Contents/MacOS"
  cp "$probe_dir/check" "$app_dir/Contents/MacOS/DaouOfficePluginPreview"
  python3 - "$app_dir/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as target:
    plistlib.dump(dict(CFBundleIdentifier='local.HappyLulu.PluginPreview',
        CFBundleExecutable='DaouOfficePluginPreview', CFBundleName='HappyLulu Plugin Preview',
        CFBundlePackageType='APPL', LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True), target)
PY
  open "$app_dir" --args "$1"
else
  "$probe_dir/check"
fi
