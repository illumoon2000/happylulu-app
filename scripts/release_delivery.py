#!/usr/bin/env python3
"""Checked local Mac release -> GitHub draft -> explicit promotion -> public readback.

check and --dry-run never contact GitHub. No signing keys are read by this tool.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "young221718/happylulu-app"
FEED_TAG = "macos-update-feed"
DOWNLOAD = f"https://github.com/{REPO}/releases/download/"
FEED_URL = f"{DOWNLOAD}{FEED_TAG}/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
APP_BUNDLE = "happylulu.app"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(args):
    return subprocess.check_output([str(x) for x in args], cwd=ROOT, text=True).strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_file(folder, name):
    relative = PurePosixPath(name)
    require(not relative.is_absolute() and relative.parts and
            all(part not in (".", "..") for part in relative.parts) and
            str(relative) == name and not re.search(r"[\s\\#]", name), "Unsafe asset path")
    path = folder.joinpath(*relative.parts)
    require(all(not folder.joinpath(*relative.parts[:i]).is_symlink()
                for i in range(1, len(relative.parts) + 1)), "Symlink asset path")
    require(path.is_file() and path.stat().st_size > 0 and
            path.resolve().is_relative_to(folder.resolve()), f"Missing/escaped asset: {name}")
    return path


def info():
    value = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["CFBundleShortVersionString"]), "Invalid version")
    require(re.fullmatch(r"[1-9][0-9]*", value["CFBundleVersion"]), "Invalid build")
    require(value["SUFeedURL"] == FEED_URL, "Unexpected app feed URL")
    return value


def names(value):
    version = value["CFBundleShortVersionString"]
    return [f"HappyLulu-{version}-universal.zip", f"HappyLulu-{version}-universal.dmg",
            "RELEASE-NOTES.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
            f"updates/HappyLulu-{version}-universal.md", "updates/appcast.xml", "build-source.json", "release.json"]


def tag(value):
    return f'macos-v{value["CFBundleShortVersionString"]}-build{value["CFBundleVersion"]}'


def checksums(folder, expected):
    entries = {}
    for line in safe_file(folder, "SHA256SUMS.txt").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        require(match is not None, "Malformed checksum line")
        digest, name = match.groups()
        require(name not in entries, "Duplicate checksum entry")
        require(name in expected, "Unexpected checksum asset")
        require(sha(safe_file(folder, name)) == digest, f"Checksum mismatch: {name}")
        entries[name] = digest
    require(set(entries) == set(expected), "Incomplete checksum manifest")
    return entries


def signature_check(feed, value, archive=None, notes=None):
    helper = ROOT / "scripts/verify-update-signatures.swift"
    if archive is None:
        run(["swift", helper, "--feed-only", feed, value["SUPublicEDKey"]])
    else:
        run(["swift", helper, feed, archive, notes, value["SUPublicEDKey"]])


def feed_check(folder, value):
    feed = safe_file(folder, "updates/appcast.xml")
    items = ET.fromstring(feed.read_bytes()).findall("./channel/item")
    require(len(items) == 1, "Expected exactly one update candidate")
    item = items[0]
    enclosures, notes = item.findall("enclosure"), item.findall(SPARKLE + "releaseNotesLink")
    require(len(enclosures) == 1 and len(notes) == 1, "Ambiguous archive or notes")
    enclosure, note = enclosures[0], notes[0]
    archive_name, note_name = names(value)[0], names(value)[5]
    prefix = DOWNLOAD + tag(value) + "/"
    require(enclosure.get("url") == prefix + archive_name, "Feed archive URL mismatch")
    require(note.text == prefix + Path(note_name).name, "Feed notes URL mismatch")
    build = item.findtext(SPARKLE + "version") or enclosure.get(SPARKLE + "version")
    version = item.findtext(SPARKLE + "shortVersionString") or enclosure.get(SPARKLE + "shortVersionString")
    require(build == value["CFBundleVersion"] and version == value["CFBundleShortVersionString"], "Feed version/build mismatch")
    archive, note_path = safe_file(folder, archive_name), safe_file(folder, note_name)
    require(enclosure.get("length") == str(archive.stat().st_size), "Feed archive length mismatch")
    require(note_path.read_bytes() == safe_file(folder, "RELEASE-NOTES.md").read_bytes(), "Signed notes differ")
    signature_check(feed, value, archive, note_path)


def archive_bundle_check(archive):
    with zipfile.ZipFile(archive) as source:
        members = set(source.namelist())
    require({name.split("/", 1)[0] for name in members} == {APP_BUNDLE},
            "ZIP must contain only happylulu.app at its root")
    require({f"{APP_BUNDLE}/Contents/Info.plist", f"{APP_BUNDLE}/Contents/MacOS/HappyLulu"} <= members,
            "ZIP bundle is missing metadata or executable")


def signing_requirement(folder):
    app = folder / APP_BUNDLE
    result = subprocess.run(["codesign", "-d", "-r-", str(app)], cwd=ROOT,
                            text=True, capture_output=True, check=True)
    lines = (result.stdout + result.stderr).splitlines()
    requirement = next((line for line in lines if line.startswith("designated => ")), "")
    require("certificate leaf" in requirement, "A fixed signing certificate is required; ad-hoc is not releasable")
    return requirement


def source_check(folder, commit):
    source = json.loads(safe_file(folder, "build-source.json").read_text())
    require(source.get("schema") == 1 and source.get("cleanSource") is True and
            source.get("sourceCommit") == commit, "Package was not built from this clean source commit")


def payload_check(folder, value):
    require(folder.name == f'{value["CFBundleShortVersionString"]}-build{value["CFBundleVersion"]}', "Release directory version/build mismatch")
    for name in names(value)[:-1]:
        safe_file(folder, name)
    source_check(folder, run(["git", "rev-parse", "HEAD"]))
    for name in ("RELEASE-NOTES.md", "LICENSE", "THIRD_PARTY_NOTICES.md"):
        require(safe_file(folder, name).read_bytes() == (ROOT / name).read_bytes(), f"Source document differs: {name}")
    feed_check(folder, value)
    run(["python3", ROOT / "scripts/verify-release.py", folder])
    return signing_requirement(folder)


def stage(folder):
    value = info()
    require(not (folder / "release.json").exists(), "Prepared release already exists; keep it intact")
    require(not run(["git", "status", "--porcelain"]), "Commit reviewed source before staging")
    requirement = payload_check(folder, value)
    commit = run(["git", "rev-parse", "HEAD"])
    metadata = {"schema": 1, "repository": REPO, "tag": tag(value), "sourceCommit": commit,
                "version": value["CFBundleShortVersionString"], "build": value["CFBundleVersion"],
                "feedURL": FEED_URL, "publicKey": value["SUPublicEDKey"], "signingRequirement": requirement}
    (folder / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (folder / "SHA256SUMS.txt").write_text("".join(f"{sha(safe_file(folder, name))}  {name}\n" for name in names(value)))
    return check(folder)


def check(folder):
    value = info()
    digests = checksums(folder, names(value))
    metadata = json.loads(safe_file(folder, "release.json").read_text())
    require(metadata.get("schema") == 1 and metadata.get("repository") == REPO and
            metadata.get("tag") == tag(value) and metadata.get("feedURL") == FEED_URL and
            metadata.get("version") == value["CFBundleShortVersionString"] and
            metadata.get("build") == value["CFBundleVersion"] and
            metadata.get("publicKey") == value["SUPublicEDKey"], "Release manifest mismatch")
    require(metadata.get("sourceCommit") == run(["git", "rev-parse", "HEAD"]), "Checkout commit differs from prepared release")
    require(not run(["git", "status", "--porcelain"]), "Checkout has uncommitted changes")
    require(payload_check(folder, value) == metadata.get("signingRequirement"), "Signing identity differs")
    return value, metadata, digests


def permission_evidence(path, metadata, digests):
    require(path is not None, "Promotion blocked: pass evidence of actual HappyLulu update and permission preservation")
    evidence = json.loads(path.read_text())
    require(evidence.get("schema") == 1 and evidence.get("sourceCommit") == metadata["sourceCommit"] and
            evidence.get("version") == metadata["version"] and evidence.get("build") == metadata["build"] and
            evidence.get("archiveSHA256") == digests[f'HappyLulu-{metadata["version"]}-universal.zip'], "Permission evidence does not match this candidate")
    for field in ("calendarPermissionPreserved", "attendancePreserved", "calendarConnectionsPreserved", "updateInstalledAndRelaunched"):
        require(evidence.get(field) is True, f"Promotion blocked: {field} is unverified")
    for field in ("testedAt", "operator", "evidence"):
        require(isinstance(evidence.get(field), str) and evidence[field].strip(), f"Missing evidence field: {field}")


def gh(*arguments):
    return ["gh", *arguments, "--repo", REPO]


def remote_release(release_tag):
    # Listing includes authenticated drafts; the by-tag endpoint only finds published releases.
    pages = json.loads(run(["gh", "api", f"repos/{REPO}/releases", "--paginate", "--slurp"]))
    matches = [release for page in pages for release in page if release["tag_name"] == release_tag]
    require(len(matches) <= 1, "Ambiguous GitHub release tag")
    return matches[0] if matches else None


def tag_check(release_tag, commit):
    refs = json.loads(run(["gh", "api", f"repos/{REPO}/git/matching-refs/tags/{release_tag}"]))
    refs = [ref for ref in refs if ref["ref"] == "refs/tags/" + release_tag]
    require(len(refs) <= 1, "Ambiguous release tag")
    if not refs:
        return
    target = refs[0]["object"]
    for _ in range(10):
        if target["type"] != "tag":
            break
        target = json.loads(run(["gh", "api", f'repos/{REPO}/git/tags/{target["sha"]}']))["object"]
    require(target["type"] == "commit" and target["sha"] == commit, "Existing release tag points to a different commit")


def asset_paths(folder, value):
    require("#" not in str(folder), "Release path must not contain a GitHub asset label separator")
    return [safe_file(folder, name) for name in names(value) + ["SHA256SUMS.txt"]]


def remote_assets(folder, value, metadata, *, public=False):
    release = remote_release(metadata["tag"])
    require(release is not None, "Version release is missing")
    if public:
        require(not release["draft"], "Version release is still a draft")
    else:
        require(release["target_commitish"] == metadata["sourceCommit"], "Draft target commit differs")
    expected = asset_paths(folder, value)
    remote_names = [asset["name"] for asset in release["assets"]]
    require(sorted(remote_names) == sorted(path.name for path in expected), "Remote asset list differs")
    with tempfile.TemporaryDirectory(prefix="happylulu-release-readback-") as temporary:
        run(gh("release", "download", metadata["tag"], "--dir", temporary))
        for path in expected:
            require(sha(Path(temporary) / path.name) == sha(path), f"Remote bytes differ: {path.name}")
    if not release["draft"]:
        commit = run(["gh", "api", f'repos/{REPO}/commits/{metadata["tag"]}', "--jq", ".sha"])
        require(commit == metadata["sourceCommit"], "Public release tag commit differs")
    return release


def draft_command(folder, value, metadata):
    return gh("release", "create", metadata["tag"], *asset_paths(folder, value), "--draft", "--latest=false",
              "--target", metadata["sourceCommit"], "--title", f'happylulu for Mac {metadata["version"]} · build {metadata["build"]}',
              "--notes-file", safe_file(folder, "RELEASE-NOTES.md"))


def public_bytes(url, expected):
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(expected.stat().st_size + 1)
    require(data == expected.read_bytes(), f"Public URL differs: {url}")


def readback(folder, value, metadata):
    remote_assets(folder, value, metadata, public=True)
    stable = remote_release(FEED_TAG)
    require(stable is not None and not stable["draft"] and stable["prerelease"], "Stable feed must be a public prerelease")
    for path in asset_paths(folder, value):
        public_bytes(DOWNLOAD + metadata["tag"] + "/" + path.name, path)
    public_bytes(FEED_URL, safe_file(folder, "updates/appcast.xml"))
    print("PASS public version assets and stable signed feed match the local candidate")


def upload_feed(feed, previous):
    try:
        run(gh("release", "upload", FEED_TAG, feed, "--clobber"))
    except subprocess.CalledProcessError:
        if previous is not None:
            with tempfile.TemporaryDirectory(prefix="happylulu-feed-recovery-") as temporary:
                backup = Path(temporary) / "appcast.xml"
                backup.write_bytes(previous)
                try:
                    run(gh("release", "upload", FEED_TAG, backup, "--clobber"))
                except subprocess.CalledProcessError as recovery:
                    raise ValueError("Feed upload and recovery failed; preserve receipts and rerun this same candidate's promote") from recovery
        raise


def missing_feed_receipt(folder, feed, metadata):
    receipt = json.loads(safe_file(folder, "receipts/feed-promotion.json").read_text())
    require(receipt.get("sourceCommit") == metadata["sourceCommit"] and
            receipt.get("candidateSHA256") == sha(feed), "Missing feed recovery does not match this candidate")
    previous = receipt.get("previousSHA256")
    if previous:
        require(isinstance(previous, str) and re.fullmatch(r"[0-9a-f]{64}", previous), "Malformed previous feed receipt")
        backup = safe_file(folder, "receipts/previous-appcast-" + previous + ".xml")
        require(sha(backup) == previous, "Previous feed receipt mismatch")
        return backup.read_bytes()
    return None


def promote(folder, value, metadata, evidence, *, dry_run=False):
    permission_evidence(evidence, metadata, checksums(folder, names(value)))
    publish = gh("release", "edit", metadata["tag"], "--draft=false", "--latest=false")
    feed = safe_file(folder, "updates/appcast.xml")
    if dry_run:
        print(shlex.join(map(str, publish)))
        print("After remote byte verification: create/update macos-update-feed as prerelease/latest=false; then public readback.")
        return
    release = remote_assets(folder, value, metadata)
    stable = remote_release(FEED_TAG)
    old_feed = None
    feed_missing = False
    if stable:
        require(stable["prerelease"] and not stable.get("immutable", False), "Stable feed release must be mutable and prerelease")
        stable_names = [asset["name"] for asset in stable["assets"]]
        require(stable_names in (["appcast.xml"], []), "Unexpected stable feed assets")
        asset = stable["assets"][0] if stable_names else {}
        feed_missing = asset.get("state") != "uploaded" or asset.get("size", 0) <= 0
        if feed_missing:
            old_feed = missing_feed_receipt(folder, feed, metadata)
        else:
            with tempfile.TemporaryDirectory(prefix="happylulu-previous-feed-") as temporary:
                run(gh("release", "download", FEED_TAG, "--pattern", "appcast.xml", "--dir", temporary))
                old_feed = (Path(temporary) / "appcast.xml").read_bytes()
    if old_feed is not None:
        with tempfile.TemporaryDirectory(prefix="happylulu-feed-verify-") as temporary:
            previous = Path(temporary) / "appcast.xml"
            previous.write_bytes(old_feed)
            signature_check(previous, value)
        previous_item = ET.fromstring(old_feed).find("./channel/item")
        require(previous_item is not None, "Invalid previous feed")
        previous_enclosure = previous_item.find("enclosure")
        old_build = previous_item.findtext(SPARKLE + "version") or (previous_enclosure.get(SPARKLE + "version") if previous_enclosure is not None else None)
        require(old_build and old_build.isdigit() and int(old_build) <= int(metadata["build"]), "Refuse stable feed rollback")
        require(int(old_build) != int(metadata["build"]) or old_feed == feed.read_bytes(), "Same build has different signed feed bytes")
    receipts = folder / "receipts"
    require(not receipts.is_symlink(), "Symlink receipt directory")
    receipts.mkdir(exist_ok=True)
    if old_feed is not None:
        (receipts / ("previous-appcast-" + hashlib.sha256(old_feed).hexdigest() + ".xml")).write_bytes(old_feed)
    (receipts / "feed-promotion.json").write_text(json.dumps({
        "sourceCommit": metadata["sourceCommit"], "candidateSHA256": sha(feed),
        "previousSHA256": hashlib.sha256(old_feed).hexdigest() if old_feed is not None else None
    }, indent=2) + "\n")
    tag_check(metadata["tag"], metadata["sourceCommit"])
    if release["draft"]:
        run(publish)
    if stable is None:
        run(gh("release", "create", FEED_TAG, feed, "--draft", "--prerelease", "--latest=false",
               "--target", metadata["sourceCommit"], "--title", "HappyLulu macOS signed update feed",
               "--notes", "Stable signed Sparkle feed. Versioned downloads are preserved in their own releases."))
    elif feed_missing or old_feed != feed.read_bytes():
        upload_feed(feed, old_feed)
    run(gh("release", "edit", FEED_TAG, "--draft=false", "--prerelease", "--latest=false"))
    readback(folder, value, metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stage", "check", "draft", "promote", "readback"))
    parser.add_argument("release", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="Offline command preview; never contacts GitHub")
    parser.add_argument("--permission-evidence", type=Path)
    args = parser.parse_args()
    require(not args.dry_run or args.action in ("draft", "promote"), "--dry-run is supported for draft/promote")
    folder = args.release.resolve(strict=True)
    value, metadata, _ = stage(folder) if args.action == "stage" else check(folder)
    if args.action == "draft":
        command = draft_command(folder, value, metadata)
        if args.dry_run:
            print(shlex.join(map(str, command)))
        else:
            tag_check(metadata["tag"], metadata["sourceCommit"])
            require(remote_release(metadata["tag"]) is None, "Release exists; refusing to overwrite")
            require(run(["gh", "api", f'repos/{REPO}/commits/{metadata["sourceCommit"]}', "--jq", ".sha"]) == metadata["sourceCommit"], "Push the reviewed source commit before creating a draft")
            run(command)
            remote_assets(folder, value, metadata)
            print("PASS draft assets read back; nothing published")
    elif args.action == "promote":
        promote(folder, value, metadata, args.permission_evidence, dry_run=args.dry_run)
    elif args.action == "readback":
        readback(folder, value, metadata)
    else:
        print(f'PASS local release {metadata["tag"]}; no remote mutation')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"FAIL release delivery: {error}")
