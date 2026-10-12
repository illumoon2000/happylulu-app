#!/usr/bin/env python3
"""Offline release safety checks; temporary files and ephemeral keys only."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import release_delivery as delivery


class ReleaseDeliveryChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = tempfile.TemporaryDirectory(prefix="happylulu-delivery-check-")
        cls.base = Path(cls.sandbox.name)
        cls.verifier = cls.base / "verify-signatures"
        subprocess.run(["swiftc", delivery.ROOT / "scripts/verify-update-signatures.swift", "-o", cls.verifier], check=True)
        fixture = cls.base / "fixture"
        fixture.mkdir()
        helper = cls.base / "fixture.swift"
        helper.write_text('''
import CryptoKit
import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let archive = Data("test archive, never an app".utf8)
let notes = Data("isolated release notes".utf8)
let archiveSignature = try key.signature(for: archive).base64EncodedString()
let notesSignature = try key.signature(for: notes).base64EncodedString()
let prefix = "https://github.com/young221718/happylulu-app/releases/download/macos-v1.5.10-build25/"
let payload = Data(("<?xml version=\\"1.0\\"?><rss xmlns:sparkle=\\"http://www.andymatuschak.org/xml-namespaces/sparkle\\"><channel><item>" +
    "<sparkle:version>25</sparkle:version><sparkle:shortVersionString>1.5.10</sparkle:shortVersionString>" +
    "<sparkle:releaseNotesLink sparkle:edSignature=\\"" + notesSignature + "\\">" + prefix + "HappyLulu-1.5.10-universal.md</sparkle:releaseNotesLink>" +
    "<enclosure url=\\"" + prefix + "HappyLulu-1.5.10-universal.zip\\" length=\\"" + String(archive.count) + "\\" sparkle:edSignature=\\"" + archiveSignature + "\\"/>" +
    "</item></channel></rss>\\n").utf8)
let trailer = "<!-- sparkle-signatures:\\nedSignature: " + (try key.signature(for: payload)).base64EncodedString() + "\\nlength: " + String(payload.count) + "\\n-->\\n"
try (payload + Data(trailer.utf8)).write(to: folder.appendingPathComponent("appcast.xml"))
try archive.write(to: folder.appendingPathComponent("archive.zip"))
try notes.write(to: folder.appendingPathComponent("notes.md"))
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: folder.appendingPathComponent("public-key.txt"))
''')
        subprocess.run(["swift", helper, fixture], check=True)
        cls.fixture = fixture

    @classmethod
    def tearDownClass(cls):
        cls.sandbox.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=self.base)
        self.folder = Path(self.temporary.name) / "1.5.10-build25"
        (self.folder / "updates").mkdir(parents=True)
        self.value = plistlib.loads((delivery.ROOT / "Resources/Info.plist").read_bytes())
        # Ephemeral signed fixture identity is independent of the current app build.
        self.value["CFBundleShortVersionString"] = "1.5.10"
        self.value["CFBundleVersion"] = "25"
        self.value["SUPublicEDKey"] = (self.fixture / "public-key.txt").read_text()
        for name in delivery.names(self.value):
            path = self.folder / name
            path.write_text("fixture " + name)
        shutil.copyfile(self.fixture / "archive.zip", self.folder / delivery.names(self.value)[0])
        shutil.copyfile(self.fixture / "notes.md", self.folder / "RELEASE-NOTES.md")
        shutil.copyfile(self.fixture / "notes.md", self.folder / delivery.names(self.value)[5])
        shutil.copyfile(self.fixture / "appcast.xml", self.folder / "updates/appcast.xml")
        self.metadata = {"version": "1.5.10", "build": "25", "sourceCommit": "a" * 40,
                         "tag": "macos-v1.5.10-build25"}
        self.write_sums()

    def tearDown(self):
        self.temporary.cleanup()

    def write_sums(self):
        self.digests = {name: delivery.sha(self.folder / name) for name in delivery.names(self.value)}
        (self.folder / "SHA256SUMS.txt").write_text("".join(f"{digest}  {name}\n" for name, digest in self.digests.items()))

    def signatures(self, feed, value, archive=None, notes=None):
        args = [self.verifier, feed, archive, notes, value["SUPublicEDKey"]] if archive else [self.verifier, "--feed-only", feed, value["SUPublicEDKey"]]
        subprocess.run(args, check=True, capture_output=True)

    def feed_check(self):
        with patch.object(delivery, "signature_check", self.signatures):
            delivery.feed_check(self.folder, self.value)

    def mutate_feed(self, old, new):
        feed = self.folder / "updates/appcast.xml"
        feed.write_bytes(feed.read_bytes().replace(old, new))

    def evidence(self, **changes):
        value = dict(self.metadata, schema=1, archiveSHA256=self.digests[delivery.names(self.value)[0]],
                     calendarPermissionPreserved=True, attendancePreserved=True,
                     calendarConnectionsPreserved=True, updateInstalledAndRelaunched=True,
                     testedAt="2026-10-08T12:00:00+09:00", operator="isolated test", evidence="fixture only")
        value.update(changes)
        path = Path(self.temporary.name) / "evidence.json"
        path.write_text(json.dumps(value))
        return path

    def test_real_ephemeral_signatures_and_feed_contract(self):
        self.feed_check()
        self.signatures(self.folder / "updates/appcast.xml", self.value)

    def test_archive_tamper_same_length_rejected(self):
        path = self.folder / delivery.names(self.value)[0]
        path.write_bytes(b"X" + path.read_bytes()[1:])
        with self.assertRaises(subprocess.CalledProcessError): self.feed_check()

    def test_notes_tamper_rejected(self):
        for name in ("RELEASE-NOTES.md", delivery.names(self.value)[5]):
            (self.folder / name).write_text("tampered")
        with self.assertRaises(subprocess.CalledProcessError): self.feed_check()

    def test_appcast_tamper_rejected(self):
        self.mutate_feed(b"<channel>", b"<channel><title>Tampered</title>")
        with self.assertRaises(subprocess.CalledProcessError): self.feed_check()

    def test_archive_feed_url_mismatch(self):
        self.mutate_feed(b"macos-v1.5.10-build25/HappyLulu-1.5.10-universal.zip", b"macos-update-feed/HappyLulu-1.5.10-universal.zip")
        with self.assertRaisesRegex(ValueError, "archive URL mismatch"): self.feed_check()

    def test_notes_feed_url_mismatch(self):
        self.mutate_feed(b"macos-v1.5.10-build25/HappyLulu-1.5.10-universal.md", b"other/notes.md")
        with self.assertRaisesRegex(ValueError, "notes URL mismatch"): self.feed_check()

    def test_feed_build_mismatch(self):
        self.mutate_feed(b"<sparkle:version>25", b"<sparkle:version>24")
        with self.assertRaisesRegex(ValueError, "version/build mismatch"): self.feed_check()

    def test_archive_length_mismatch(self):
        (self.folder / delivery.names(self.value)[0]).write_text("different size")
        with self.assertRaisesRegex(ValueError, "length mismatch"): self.feed_check()

    def test_checksums_valid(self):
        self.assertEqual(delivery.checksums(self.folder, delivery.names(self.value)), self.digests)

    def test_bad_checksum(self):
        (self.folder / "LICENSE").write_text("changed")
        with self.assertRaisesRegex(ValueError, "Checksum mismatch"): delivery.checksums(self.folder, delivery.names(self.value))

    def test_package_source_commit_and_clean_guard(self):
        path = self.folder / "build-source.json"
        for source, passes in [
            ({"schema": 1, "sourceCommit": "a" * 40, "cleanSource": True}, True),
            ({"schema": 1, "sourceCommit": "b" * 40, "cleanSource": True}, False),
            ({"schema": 1, "sourceCommit": "a" * 40, "cleanSource": False}, False),
        ]:
            path.write_text(json.dumps(source))
            if passes:
                delivery.source_check(self.folder, "a" * 40)
            else:
                with self.assertRaisesRegex(ValueError, "clean source commit"):
                    delivery.source_check(self.folder, "a" * 40)

    def test_missing_checksum(self):
        path = self.folder / "SHA256SUMS.txt"
        path.write_text("\n".join(path.read_text().splitlines()[:-1]) + "\n")
        with self.assertRaisesRegex(ValueError, "Incomplete"): delivery.checksums(self.folder, delivery.names(self.value))

    def test_duplicate_checksum(self):
        path = self.folder / "SHA256SUMS.txt"
        path.write_text(path.read_text() + path.read_text().splitlines()[0] + "\n")
        with self.assertRaisesRegex(ValueError, "Duplicate"): delivery.checksums(self.folder, delivery.names(self.value))

    def test_malformed_checksum(self):
        (self.folder / "SHA256SUMS.txt").write_text("not-a-hash  LICENSE\n")
        with self.assertRaisesRegex(ValueError, "Malformed"): delivery.checksums(self.folder, delivery.names(self.value))

    def test_paths_traversal_absolute_and_shell_labels_rejected(self):
        for name in ("../LICENSE", "/etc/hosts", "updates/../LICENSE", "LICENSE#label", "updates//appcast.xml", "LICENSE\n"):
            with self.subTest(name=name), self.assertRaises(ValueError): delivery.safe_file(self.folder, name)

    def test_symlink_path_rejected(self):
        (self.folder / "LICENSE").unlink()
        (self.folder / "LICENSE").symlink_to(self.fixture / "notes.md")
        with self.assertRaisesRegex(ValueError, "Symlink"): delivery.safe_file(self.folder, "LICENSE")

    def test_permission_guard_missing_and_incomplete(self):
        with patch.object(delivery, "run") as command:
            with self.assertRaisesRegex(ValueError, "Promotion blocked"): delivery.promote(self.folder, self.value, self.metadata, None)
            with self.assertRaisesRegex(ValueError, "unverified"):
                delivery.promote(self.folder, self.value, self.metadata, self.evidence(calendarPermissionPreserved=False))
            command.assert_not_called()

    def test_permission_guard_wrong_candidate(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            delivery.permission_evidence(self.evidence(archiveSHA256="0" * 64), self.metadata, self.digests)

    def test_dry_runs_never_contact_github(self):
        for action in ("draft", "promote"):
            args = ["release_delivery.py", action, str(self.folder), "--dry-run", "--permission-evidence", str(self.evidence())]
            with self.subTest(action=action), patch.object(sys, "argv", args), patch.object(delivery, "check", return_value=(self.value, self.metadata, self.digests)), patch.object(delivery, "run") as command, patch.object(delivery, "remote_release") as remote, contextlib.redirect_stdout(io.StringIO()):
                delivery.main()
                command.assert_not_called()
                remote.assert_not_called()

    def test_draft_is_visible_in_authenticated_list(self):
        draft = {"tag_name": self.metadata["tag"], "draft": True}
        with patch.object(delivery, "run", return_value=json.dumps([[draft]])):
            self.assertEqual(delivery.remote_release(self.metadata["tag"]), draft)

    def test_remote_mismatch_stops_before_promotion(self):
        with patch.object(delivery, "remote_assets", side_effect=ValueError("Remote bytes differ")), patch.object(delivery, "run") as command:
            with self.assertRaisesRegex(ValueError, "Remote bytes differ"):
                delivery.promote(self.folder, self.value, self.metadata, self.evidence())
            command.assert_not_called()

    def test_existing_wrong_tag_blocks_draft_and_promotion_before_mutation(self):
        wrong_tag = [{"ref": "refs/tags/" + self.metadata["tag"],
                      "object": {"type": "commit", "sha": "b" * 40}}]
        for action in ("draft", "promote"):
            commands = []
            def command(args):
                commands.append(args)
                return json.dumps(wrong_tag)
            args = ["release_delivery.py", action, str(self.folder), "--permission-evidence", str(self.evidence())]
            with self.subTest(action=action), patch.object(sys, "argv", args), patch.object(delivery, "check", return_value=(self.value, self.metadata, self.digests)), patch.object(delivery, "run", side_effect=command), patch.object(delivery, "remote_release", return_value=None), patch.object(delivery, "remote_assets", return_value={"draft": True}):
                with self.assertRaisesRegex(ValueError, "different commit"):
                    delivery.main()
                self.assertTrue(commands)
                self.assertTrue(all(args[1] == "api" for args in commands))

    def test_annotated_tag_is_peeled_to_commit(self):
        reference = [{"ref": "refs/tags/" + self.metadata["tag"], "object": {"type": "tag", "sha": "b" * 40}}]
        with patch.object(delivery, "run", side_effect=[json.dumps(reference), json.dumps({"object": {"type": "commit", "sha": "a" * 40}})]):
            delivery.tag_check(self.metadata["tag"], "a" * 40)

    def test_failed_feed_upload_restores_previous_signed_bytes(self):
        commands = []
        previous = (self.fixture / "appcast.xml").read_bytes()
        def command(args):
            commands.append(args)
            if len(commands) == 1:
                raise subprocess.CalledProcessError(1, args)
            self.assertEqual(Path(args[4]).name, "appcast.xml")
            self.assertEqual(Path(args[4]).read_bytes(), previous)
            return ""
        with patch.object(delivery, "run", side_effect=command):
            with self.assertRaises(subprocess.CalledProcessError):
                delivery.upload_feed(self.folder / "updates/appcast.xml", previous)
        self.assertEqual(len(commands), 2)

    def test_missing_feed_recovery_requires_matching_receipt_and_backup(self):
        feed = self.folder / "updates/appcast.xml"
        with self.assertRaises(ValueError): delivery.missing_feed_receipt(self.folder, feed, self.metadata)
        receipts = self.folder / "receipts"
        receipts.mkdir()
        digest = delivery.sha(feed)
        (receipts / ("previous-appcast-" + digest + ".xml")).write_bytes(feed.read_bytes())
        receipt = {"sourceCommit": "a" * 40, "candidateSHA256": digest, "previousSHA256": digest}
        (receipts / "feed-promotion.json").write_text(json.dumps(receipt))
        self.assertEqual(delivery.missing_feed_receipt(self.folder, feed, self.metadata), feed.read_bytes())
        receipt["candidateSHA256"] = "0" * 64
        (receipts / "feed-promotion.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "does not match"):
            delivery.missing_feed_receipt(self.folder, feed, self.metadata)

    def test_incomplete_feed_asset_resumes_via_signed_receipt(self):
        feed = self.folder / "updates/appcast.xml"
        receipts = self.folder / "receipts"
        receipts.mkdir()
        digest = delivery.sha(feed)
        (receipts / ("previous-appcast-" + digest + ".xml")).write_bytes(feed.read_bytes())
        (receipts / "feed-promotion.json").write_text(json.dumps({
            "sourceCommit": self.metadata["sourceCommit"], "candidateSHA256": digest,
            "previousSHA256": digest
        }))
        for state, size in (("starter", 0), ("starter", 1), ("uploaded", 0)):
            asset = {"name": "appcast.xml", "state": state, "size": size}
            stable = {"prerelease": True, "assets": [asset]}
            commands = []
            with self.subTest(state=state, size=size), patch.object(delivery, "remote_assets", return_value={"draft": False}), patch.object(delivery, "remote_release", return_value=stable), patch.object(delivery, "tag_check"), patch.object(delivery, "signature_check", self.signatures), patch.object(delivery, "run", side_effect=lambda args: commands.append(args) or ""), patch.object(delivery, "readback") as readback:
                delivery.promote(self.folder, self.value, self.metadata, self.evidence())
                self.assertEqual(len(commands), 2)
                self.assertEqual(commands[0], delivery.gh("release", "upload", delivery.FEED_TAG, feed, "--clobber"))
                self.assertEqual(commands[1], delivery.gh("release", "edit", delivery.FEED_TAG, "--draft=false", "--prerelease", "--latest=false"))
                readback.assert_called_once()

    def test_incomplete_feed_asset_without_receipt_cannot_mutate(self):
        stable = {"prerelease": True, "assets": [{"name": "appcast.xml", "state": "starter", "size": 0}]}
        with patch.object(delivery, "remote_assets", return_value={"draft": False}), patch.object(delivery, "remote_release", return_value=stable), patch.object(delivery, "run") as command:
            with self.assertRaisesRegex(ValueError, "Missing/escaped asset"):
                delivery.promote(self.folder, self.value, self.metadata, self.evidence())
            command.assert_not_called()

    def test_incomplete_feed_asset_with_invalid_signed_backup_cannot_mutate(self):
        feed = self.folder / "updates/appcast.xml"
        receipts = self.folder / "receipts"
        receipts.mkdir()
        previous = feed.read_bytes().replace(b"<channel>", b"<channel><title>Tampered</title>")
        digest = hashlib.sha256(previous).hexdigest()
        (receipts / ("previous-appcast-" + digest + ".xml")).write_bytes(previous)
        (receipts / "feed-promotion.json").write_text(json.dumps({
            "sourceCommit": self.metadata["sourceCommit"], "candidateSHA256": delivery.sha(feed),
            "previousSHA256": digest
        }))
        stable = {"prerelease": True, "assets": [{"name": "appcast.xml", "state": "starter", "size": 0}]}
        with patch.object(delivery, "remote_assets", return_value={"draft": False}), patch.object(delivery, "remote_release", return_value=stable), patch.object(delivery, "signature_check", self.signatures), patch.object(delivery, "run") as command:
            with self.assertRaises(subprocess.CalledProcessError):
                delivery.promote(self.folder, self.value, self.metadata, self.evidence())
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
