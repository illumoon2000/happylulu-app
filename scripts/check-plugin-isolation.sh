#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp/}HappyLulu-no-plugin.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
cp "$project_dir/Package.swift" "$project_dir/Package.resolved" "$probe_dir/"
rsync -a --exclude DaouOfficePlugin --exclude DaouOfficeIntegration --exclude AIUsagePlugin --exclude AIUsageIntegration "$project_dir/Sources/" "$probe_dir/Sources/"
rsync -a "$project_dir/Tests/" "$probe_dir/Tests/"
mkdir -p "$probe_dir/scripts" "$probe_dir/.build"
cp "$project_dir/scripts/check-plugin-architecture.sh" "$probe_dir/scripts/"
# Reuse the already resolved dependency; no new packages are installed for this check.
for item in checkouts artifacts repositories workspace-state.json; do
    if [[ -e "$project_dir/.build/$item" ]]; then
        cp -R "$project_dir/.build/$item" "$probe_dir/.build/"
    fi
done
test ! -e "$probe_dir/Sources/DaouOfficePlugin"
test ! -e "$probe_dir/Sources/DaouOfficeIntegration"
test ! -e "$probe_dir/Sources/AIUsagePlugin"
test ! -e "$probe_dir/Sources/AIUsageIntegration"
cd "$probe_dir"
swift build --build-system native --disable-automatic-resolution --skip-update --product HappyLulu
binary_dir="$(swift build --build-system native --show-bin-path)"
test ! -e "$binary_dir/Modules/DaouOfficePlugin.swiftmodule"
test ! -e "$binary_dir/Modules/DaouOfficeIntegration.swiftmodule"
test ! -e "$binary_dir/Modules/AIUsagePlugin.swiftmodule"
test ! -e "$binary_dir/Modules/AIUsageIntegration.swiftmodule"
test "$("$binary_dir/HappyLulu" --plugin-modules)" = "cpu-runner"
swift run --build-system native AfterSixChecks
bash scripts/check-plugin-architecture.sh
printf 'PASS plugin removal: Daouoffice and AI usage source modules absent; base app builds, runs composition diagnostics and passes attendance/host checks.\n'
