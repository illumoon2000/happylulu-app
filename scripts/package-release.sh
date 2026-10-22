#!/bin/bash
# Builds a fresh, data-free Universal app without replacing the installed app.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Invalid release version/build\n' >&2; exit 1
fi
for required in LICENSE THIRD_PARTY_NOTICES.md RELEASE-NOTES.md; do
  test -s "$required" || { printf 'Missing release document: %s\n' "$required" >&2; exit 1; }
done
release_dir="$project_dir/dist/releases/$version-build$build"
if [[ -e "$release_dir" ]]; then
  printf 'Release already exists; keep it intact: %s\n' "$release_dir" >&2
  exit 1
fi
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.release-stage.XXXXXX")"
app_dir="$staging_dir/HappyLulu.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
python3 - "$staging_dir/build-source.json" <<'PY'
import json,subprocess,sys
source = {'schema': 1,
          'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'cleanSource': not subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()}
with open(sys.argv[1], 'w') as output:
    json.dump(source, output, indent=2)
    output.write('\n')
PY

for architecture in arm64 x86_64; do
  swift build --build-system native -c release --product HappyLulu \
    --scratch-path "$project_dir/.build/distribution-$architecture" \
    --triple "$architecture-apple-macosx13.0" --disable-local-rpath -debug-info-format none -j 4
done
arm_dir="$(swift build --build-system native -c release --show-bin-path --scratch-path "$project_dir/.build/distribution-arm64" --triple arm64-apple-macosx13.0)"
intel_dir="$(swift build --build-system native -c release --show-bin-path --scratch-path "$project_dir/.build/distribution-x86_64" --triple x86_64-apple-macosx13.0)"
lipo -create "$arm_dir/HappyLulu" "$intel_dir/HappyLulu" -output "$app_dir/Contents/MacOS/HappyLulu"
architectures=" $(lipo "$app_dir/Contents/MacOS/HappyLulu" -archs) "
for architecture in arm64 x86_64; do
  case "$architectures" in *" $architecture "*) ;; *) printf 'Missing architecture: %s\n' "$architecture" >&2; exit 1;; esac
done
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp Resources/HappyLuluBrand.png "$app_dir/Contents/Resources/"
cp -R Resources/OwlStates "$app_dir/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
for language in ko en; do
    mkdir -p "$app_dir/Contents/Resources/$language.lproj"
    cp "Resources/$language.lproj/InfoPlist.strings" "$app_dir/Contents/Resources/$language.lproj/InfoPlist.strings"
done
bash scripts/embed-sparkle.sh "$app_dir" "$project_dir/.build/distribution-arm64"
swift scripts/make-icon.swift "$project_dir/Resources/HappyLuluIcon.png" "$staging_dir/HappyLulu.iconset"
iconutil -c icns "$staging_dir/HappyLulu.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
bash scripts/sign-app.sh "$app_dir"

mkdir -p "$release_dir"
cp "$staging_dir/build-source.json" "$release_dir/"
cp -R "$app_dir" "$release_dir/HappyLulu.app"
ditto -c -k --keepParent --norsrc --noextattr "$app_dir" "$release_dir/HappyLulu-$version-universal.zip"
image_source="$staging_dir/image"
mkdir -p "$image_source"
cp -R "$app_dir" "$image_source/HappyLulu.app"
ln -s /Applications "$image_source/Applications"
cp RELEASE-NOTES.md "$image_source/시작하기.txt"
cp LICENSE THIRD_PARTY_NOTICES.md "$image_source/"
hdiutil create -volname "HappyLulu $version" -srcfolder "$image_source" -format UDZO \
  -o "$release_dir/HappyLulu-$version-universal.dmg"
cp RELEASE-NOTES.md "$release_dir/RELEASE-NOTES.md"
cp LICENSE THIRD_PARTY_NOTICES.md "$release_dir/"
(
  cd "$release_dir"
  shasum -a 256 "HappyLulu-$version-universal.zip" "HappyLulu-$version-universal.dmg" \
    RELEASE-NOTES.md LICENSE THIRD_PARTY_NOTICES.md build-source.json > SHA256SUMS.txt
)
printf 'Release: %s\n' "$release_dir"
printf 'Apple notarization has not been performed.\n'
printf 'Staging retained for inspection: %s\n' "$staging_dir"
