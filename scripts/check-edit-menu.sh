#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${HAPPY_LULU_SKIP_BUILD:-0}" != "1" ]]; then
  swift build --build-system native --product HappyLulu >/dev/null
fi
build_dir="$(swift build --build-system native --show-bin-path)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-edit-menu.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
app="$probe_dir/EditMenuProbe.app"
mkdir -p "$app/Contents/MacOS" "$probe_dir/data"
python3 - "$probe_dir/main.swift" "$app/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys, uuid
source = pathlib.Path("Sources/AfterSix/main.swift").read_text()
marker = "\nlet application = NSApplication.shared\n"
assert source.count(marker) == 1, "Application bootstrap changed; review the probe"
bootstrap = marker + source.split(marker)[1]
assert bootstrap.count("AppDelegate()") == 1
# Keep the production bootstrap, including its menu installation, and replace only
# the delegate that would otherwise start attendance, login items and integrations.
bootstrap = bootstrap.replace("AppDelegate()", "PasteProbeDelegate()")
pathlib.Path(sys.argv[1]).write_text(pathlib.Path("Tests/EditMenuProbe/main.swift").read_text() + bootstrap)
with pathlib.Path(sys.argv[2]).open("wb") as stream:
    plistlib.dump(dict(CFBundleIdentifier="local.happylulu.edit-menu-probe." + uuid.uuid4().hex,
        CFBundleExecutable="EditMenuProbe", CFBundleName="EditMenuProbe", CFBundlePackageType="APPL",
        LSUIElement=True), stream)
PY
menu_sources=(Sources/AfterSix/AppLanguage.swift)
if [[ -f Sources/AfterSix/ApplicationMenu.swift ]]; then
  menu_sources+=(Sources/AfterSix/ApplicationMenu.swift)
fi
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PWD/.build/edit-menu-module-cache" -I "$build_dir/Modules" \
  "${menu_sources[@]}" \
  Sources/DaouOfficeIntegration/DaouOfficePluginModel.swift \
  Sources/DaouOfficeIntegration/DaouOfficePluginSettingsView.swift "$probe_dir/main.swift" \
  "$build_dir"/AppPluginHost.build/*.swift.o "$build_dir"/AppPluginCore.build/*.swift.o \
  "$build_dir"/DaouOfficePlugin.build/*.swift.o "$build_dir"/AfterSixCore.build/*.swift.o \
  "$build_dir"/CalendarSyncServices.build/*.swift.o "$build_dir"/CalendarSyncCore.build/*.swift.o \
  -framework AppKit -framework SwiftUI -framework Security -framework EventKit -lsqlite3 \
  -o "$app/Contents/MacOS/EditMenuProbe"
python3 - "$app/Contents/MacOS/EditMenuProbe" "$probe_dir/data" <<'PYTHON'
import subprocess, sys
sys.exit(subprocess.run(sys.argv[1:], timeout=30).returncode)
PYTHON
