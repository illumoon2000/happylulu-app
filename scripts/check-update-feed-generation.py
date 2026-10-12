#!/usr/bin/env python3
"""Local integration check; uses existing signing keys and never publishes."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
import release_delivery as delivery

archive = Path(sys.argv[1]).resolve(strict=True)
original_notes = (archive.parent / "RELEASE-NOTES.md").read_bytes()
value = plistlib.loads((delivery.ROOT / "Resources/Info.plist").read_bytes())
with tempfile.TemporaryDirectory(prefix="happylulu-feed-generation-") as temporary:
    folder = Path(temporary)
    shutil.copyfile(archive, folder / archive.name)
    (folder / "RELEASE-NOTES.md").write_bytes(original_notes)
    subprocess.run(["bash", delivery.ROOT / "scripts/generate-update-feed.sh",
                    folder / archive.name], check=True)
    notes = folder / "updates" / (archive.stem + ".md")
    delivery.require(notes.read_bytes() == original_notes,
                     "Generated signed notes must preserve release notes bytes")
    delivery.feed_check(folder, value)
    # Match both notes copies so equality alone cannot detect the tampering.
    tampered = original_notes + b"\nModified after signing.\n"
    notes.write_bytes(tampered)
    (folder / "RELEASE-NOTES.md").write_bytes(tampered)
    try:
        delivery.feed_check(folder, value)
    except (ValueError, subprocess.CalledProcessError):
        pass
    else:
        raise AssertionError("Modified signed notes must fail signature verification")
print("PASS real feed generation preserves release notes, verifies signatures, rejects note tampering; no publication")
