"""Validate the source-only marketing site; never fetch or publish releases."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import json

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
REPO = "https://github.com/young221718/happylulu-app"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = []

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if "id" in fields:
            assert fields["id"] not in self.ids, "Duplicate anchor"
            self.ids.add(fields["id"])
        self.links.extend(fields[k] for k in ("href", "src") if k in fields)


pages = {}
for document in DIST.rglob("*.html"):
    page = Page()
    page.feed(document.read_text())
    pages[document.resolve()] = page
assert len(pages) == 11, "Preserve existing routes and the Korean/English overtime guides"
for route in ("features/overtime/index.html", "en/features/overtime/index.html"):
    assert (DIST / route).resolve() in pages, route
links = []
for document, page in pages.items():
    assert REPO + "/blob/main/LICENSE" in page.links, document
    for link in page.links:
        links.append(link)
        url = urlsplit(link)
        if url.scheme or url.netloc:
            assert url.scheme == "https", link
            continue
        target = DIST / url.path.lstrip("/") if url.path.startswith("/") else document.parent / url.path
        if not url.path:
            target = document
        elif url.path.endswith("/") or target.is_dir():
            target /= "index.html"
        target = target.resolve()
        assert target.is_relative_to(DIST.resolve()) and target.is_file(), (document, link)
        if url.fragment and target in pages:
            assert url.fragment in pages[target].ids, (document, link)
for tag, asset in [
    ("macos-v1.5.12-build28", "HappyLulu-1.5.12-universal.dmg"),
    ("macos-v1.5.12-build28", "HappyLulu-1.5.12-universal.zip"),
    ("windows-v1.5.12", "HappyLulu-1.5.12-windows-x64-runtime-required.zip"),
]:
    assert REPO + f"/releases/download/{tag}/{asset}" in links, asset
assert not any("/downloads/" in urlsplit(link).path for link in links), "Use GitHub release assets"
for path in DIST.rglob("*"):
    assert not path.is_symlink(), path
    assert path.suffix not in {".zip", ".dmg", ".exe", ".p12", ".key"}, path
assert json.loads((ROOT / ".openai/hosting.json").read_text())["project_id"] == "appgprj_6abcb381750c819189cb642ebfa52b3e"
print("PASS: 11 routes, local assets/anchors, GitHub release links, license notices; no app binaries.")
