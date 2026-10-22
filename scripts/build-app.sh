#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
for required in LICENSE THIRD_PARTY_NOTICES.md; do
    test -s "$required" || { printf 'Missing release document: %s\n' "$required" >&2; exit 1; }
done
swift build --build-system native -c release --product HappyLulu --disable-local-rpath
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app_dir="$project_dir/dist/happylulu.app"
for existing_app in "$project_dir/dist/"*.app; do
    # A case-insensitive volume otherwise keeps the old physical folder name.
    if [[ "$existing_app" -ef "$app_dir" && "${existing_app##*/}" != "happylulu.app" ]]; then
        rename_dir="$(mktemp -d "$project_dir/dist/.app-name.XXXXXX")"
        mv "$existing_app" "$rename_dir/happylulu.app"
        mv "$rename_dir/happylulu.app" "$app_dir"
        rmdir "$rename_dir"
    fi
done
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/HappyLulu" "$app_dir/Contents/MacOS/HappyLulu"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/HappyLuluBrand.png "$app_dir/Contents/Resources/"
cp -R Resources/OwlStates "$app_dir/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
for language in ko en; do
    mkdir -p "$app_dir/Contents/Resources/$language.lproj"
    cp "Resources/$language.lproj/InfoPlist.strings" "$app_dir/Contents/Resources/$language.lproj/InfoPlist.strings"
done
bash scripts/embed-sparkle.sh "$app_dir"
swift scripts/make-icon.swift "$project_dir/Resources/HappyLuluIcon.png" "$project_dir/.build/HappyLulu.iconset"
iconutil -c icns "$project_dir/.build/HappyLulu.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
bash scripts/sign-app.sh "$app_dir"
printf 'Built: %s\n' "$app_dir"
