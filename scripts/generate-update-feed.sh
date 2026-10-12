#!/bin/bash
# Produces a signed, data-free update feed locally. Does not publish it.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
archive="${1:?Pass a packaged Universal HappyLulu ZIP}"
archive="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$archive")"
updates_dir="${2:-$(dirname "$archive")/updates}"
tools_dir="$project_dir/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$tools_dir/generate_appcast" ]]; then
  printf 'Sparkle tools missing; run swift package resolve first.\n' >&2
  exit 1
fi
feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist)"
expected_feed='https://github.com/young221718/happylulu-app/releases/download/macos-update-feed/appcast.xml'
test "$feed_url" = "$expected_feed" || { printf 'Unexpected stable GitHub feed URL.\n' >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || exit 1
filename="$(basename "$archive")"
test "$filename" = "HappyLulu-$version-universal.zip" || { printf 'Archive/version mismatch.\n' >&2; exit 1; }
test ! -e "$updates_dir" || { printf 'Keep existing signed update directory intact: %s\n' "$updates_dir" >&2; exit 1; }
mkdir -p "$updates_dir"
cp "$archive" "$updates_dir/$filename"
cp "$(dirname "$archive")/RELEASE-NOTES.md" "$updates_dir/${filename%.zip}.md"
download_prefix="https://github.com/young221718/happylulu-app/releases/download/macos-v$version-build$build/"
# Keep signed notes byte-identical to the packaged notes; signatures stay enabled.
"$tools_dir/generate_appcast" --account happylulu-updates \
  --disable-signing-warning \
  --download-url-prefix "$download_prefix" \
  --release-notes-url-prefix "$download_prefix" \
  --maximum-deltas 0 "$updates_dir"
printf 'Signed update files: %s\n' "$updates_dir"
