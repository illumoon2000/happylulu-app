"""Validate the source-only marketing site; never fetch or publish releases."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import json
import re

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
REPO = "https://github.com/young221718/happylulu-app"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.links = []
        self.language = None
        self.headings = 0
        self.alternates = {}
        self.refreshes = []
        self.docs_shell = False
        self.detail_body = False
        self.section_links = {}
        self.section_current = {}
        self.section_toggles = set()
        self.release_cards = {}
        self._navigation = None
        self._release = None

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if "docs-layout" in fields.get("class", "").split():
            self.docs_shell = True
        if "detail-body" in fields.get("class", "").split():
            self.detail_body = True
        if tag == "nav" and fields.get("id") in {"feature-navigation", "release-navigation"}:
            self._navigation = fields["id"]
            self.section_links[self._navigation] = []
            self.section_current[self._navigation] = []
        if tag == "button" and "data-section-nav-toggle" in fields:
            self.section_toggles.add(fields.get("aria-controls"))
        if tag == "a" and self._navigation:
            self.section_links[self._navigation].append(fields.get("href"))
            if fields.get("aria-current") == "page":
                self.section_current[self._navigation].append(fields.get("href"))
        if tag == "article" and "data-release-slug" in fields:
            self._release = fields["data-release-slug"]
            self.release_cards[self._release] = {"links": [], "changes": 0}
        if self._release:
            if tag == "a":
                self.release_cards[self._release]["links"].append(fields.get("href"))
            if tag == "li":
                self.release_cards[self._release]["changes"] += 1
        if tag == "html":
            self.language = fields.get("lang")
        if tag == "h1":
            self.headings += 1
        if tag == "link" and fields.get("rel") == "alternate":
            self.alternates[fields.get("hreflang")] = fields.get("href")
        if tag == "meta" and fields.get("http-equiv", "").lower() == "refresh":
            self.refreshes.append(fields.get("content"))
        if "id" in fields:
            assert fields["id"] not in self.ids, "Duplicate anchor"
            self.ids.add(fields["id"])
        self.links.extend(fields[k] for k in ("href", "src") if k in fields)

    def handle_endtag(self, tag):
        if tag == "nav":
            self._navigation = None
        if tag == "article":
            self._release = None


class OnboardingSteps(HTMLParser):
    """Check the repeated read-only calendar path before optional writes."""
    def __init__(self, section):
        super().__init__()
        self.section = section
        self.active = section is None
        self.inside = False
        self.parts = []
        self.steps = []

    def handle_starttag(self, tag, attrs):
        if tag == "section" and dict(attrs).get("id") == self.section:
            self.active = True
        if tag == "li" and self.active:
            self.inside = True
            self.parts = []

    def handle_data(self, data):
        if self.inside:
            self.parts.append(data)

    def handle_endtag(self, tag):
        if tag == "li" and self.inside:
            self.steps.append(" ".join("".join(self.parts).split()))
            self.inside = False
        if tag == "section" and self.section is not None:
            self.active = False


pages = {}
for document in DIST.rglob("*.html"):
    page = Page()
    page.feed(document.read_text())
    pages[document.resolve()] = page
legacy_routes = ("index.html", "en/index.html", "download/index.html", "features/index.html",
                 "features/overtime/index.html", "en/features/overtime/index.html",
                 "calendar/index.html", "install/index.html", "faq/index.html",
                 "releases/index.html", "en/releases/index.html")
features = ("attendance", "arrival-time", "workday-modes", "countdown", "history", "calendar",
            "plugins", "daouoffice", "leave-recognition", "appearance", "overtime", "updates")
releases = {"macos-1.5.15": "macos-v1.5.15-build31", "macos-1.5.14": "macos-v1.5.14-build30",
            "windows-1.5.13": "windows-v1.5.13"}
for route in legacy_routes:
    assert (DIST / route).resolve() in pages, route
for prefix in ("", "en/"):
    for group, entries, navigation in (("features", features, "feature-navigation"),
                                       ("releases", releases, "release-navigation")):
        overview = f"/{prefix}{group}/"
        expected = {overview, *(f"/{prefix}{group}/{slug}/" for slug in entries)}
        overview_page = pages[(DIST / prefix / group / "index.html").resolve()]
        for route in expected:
            page = pages[(DIST / route.lstrip("/") / "index.html").resolve()]
            assert page.docs_shell, f"List and details must share the sidebar layout: {route}"
            assert navigation in page.section_toggles, f"Mobile selection must control its navigation: {route}"
            assert set(page.section_links.get(navigation, [])) == expected, f"Incomplete section navigation: {route}"
            assert page.section_links[navigation] == overview_page.section_links[navigation], f"Navigation order changed: {route}"
            assert page.section_current[navigation] == [route], f"Selected section must be marked: {route}"
    listing = pages[(DIST / prefix / "releases/index.html").resolve()]
    assert set(listing.release_cards) == set(releases), "Release list must explain every version"
    for slug, tag in releases.items():
        card = listing.release_cards[slug]
        version = slug.split("-", 1)[1]
        asset = (f"HappyLulu-{version}-universal.dmg" if slug.startswith("macos-")
                 else f"HappyLulu-{version}-windows-x64-runtime-required.zip")
        assert card["changes"] >= 2, f"Show key changes without opening the release: {slug}"
        assert REPO + f"/releases/download/{tag}/{asset}" in card["links"], f"Download directly from the release list: {slug}"
calendar_paths = {"features/calendar/index.html": "how", "en/features/calendar/index.html": "how",
                  "guide/index.html": "plugins", "en/guide/index.html": "plugins",
                  "calendar/index.html": None}
calendar_steps = (r"첫 일정 조회.*읽기 권한|first event lookup.*read access",
                  r"표시할 캘린더|calendars to display", r"일정 새로고침|Refresh events",
                  r"조회만.*여기까지|Stop here if you only want to view events",
                  r"첫 동기화 미리보기|Preview first sync|first sync preview",
                  r"양방향 동기화 시작|Start two-way sync|Start bidirectional sync")
for route, section in calendar_paths.items():
    parser = OnboardingSteps(section)
    parser.feed((DIST / route).read_text())
    text = " ".join(parser.steps)
    positions = []
    for step in calendar_steps:
        match = re.search(step, text, re.I)
        assert match, f"Calendar help must explain read-only setup before sync: {route}: {step}"
        positions.append(match.start())
    assert positions == sorted(positions), f"Read-only setup must precede optional sync: {route}"
for prefix, language in (("", "ko"), ("en/", "en")):
    route = f"/{prefix}guide/"
    document = (DIST / route.lstrip("/") / "index.html").resolve()
    assert document in pages, f"Detailed usage must stay on this site: {route}"
    guide = pages[document]
    assert not guide.refreshes and guide.language == language and guide.headings == 1, route
    assert {"install", "first-run", "daily", "edit-arrival", "workday", "plugins", "appearance",
            "history", "updates", "troubleshooting", "platforms"} <= guide.ids, route
    assert guide.alternates.get("ko") == "/guide/" and guide.alternates.get("en") == "/en/guide/", route
for home in ("index.html", "en/index.html"):
    assert {"download", "features", "how", "calendar", "calendar-faq", "faq", "install",
            "releases", "release-title", "mac-releases", "windows-releases"} <= pages[(DIST / home).resolve()].ids, home
for prefix, language in (("", "ko"), ("en/", "en")):
    for group, entries in (("features", features), ("releases", releases)):
        index = (DIST / prefix / group / "index.html").resolve()
        assert index in pages, f"Missing {language} {group} overview"
        assert not pages[index].refreshes, f"Keep {group} browsing on this site"
        if group == "releases":
            assert {"mac", "windows"} <= pages[index].ids, "Preserve platform release anchors"
        for slug in entries:
            route = f"/{prefix}{group}/{slug}/"
            document = (DIST / route.lstrip("/") / "index.html").resolve()
            assert document in pages, f"Missing detail page: {route}"
            page = pages[document]
            assert route in pages[index].links, f"Overview must link to {route}"
            assert page.language == language and page.headings == 1, route
            assert page.alternates.get("ko") == f"/{group}/{slug}/", route
            assert page.alternates.get("en") == f"/en/{group}/{slug}/", route
            if group == "features":
                assert {"overview", "how", "example", "limits", "related"} <= page.ids, route
                assert f"/{prefix}features/" in page.links, f"Missing overview link: {route}"
            else:
                assert page.detail_body, f"Preserve readable release body and inline link styles: {route}"
                assert {"highlights", "improvements", "scope", "downloads"} <= page.ids, route
                assert REPO + "/releases/tag/" + releases[slug] in page.links, route
                assert any(link.startswith(f"/{prefix}features/") for link in page.links), route
links = []
for document, page in pages.items():
    assert REPO + "/blob/main/LICENSE" in page.links, document
    guide_route = "/en/guide/" if document.is_relative_to((DIST / "en").resolve()) else "/guide/"
    assert guide_route in page.links, f"Every page must expose the on-site usage guide: {document}"
    assert not page.refreshes, f"Keep help and release browsing on this site: {document}"
    for link in page.links:
        links.append(link)
        url = urlsplit(link)
        if url.scheme or url.netloc:
            assert url.scheme == "https", link
            if url.netloc == "github.com" and "/blob/main/" in url.path:
                assert not url.path.endswith(("USER-GUIDE.md", "USER-GUIDE.en.md", "README.md", "README.en.md",
                                               "CALENDAR.md", "PLUGINS.md", "UPDATES.md")), f"Usage must link to an on-site guide: {document} {link}"
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
    ("macos-v1.5.15-build31", "HappyLulu-1.5.15-universal.dmg"),
    ("macos-v1.5.15-build31", "HappyLulu-1.5.15-universal.zip"),
    ("windows-v1.5.13", "HappyLulu-1.5.13-windows-x64-runtime-required.zip"),
]:
    assert REPO + f"/releases/download/{tag}/{asset}" in links, asset
for entry in ("index.html", "en/index.html", "download/index.html"):
    page = pages[(DIST / entry).resolve()]
    for asset in ("HappyLulu-1.5.15-universal.dmg", "HappyLulu-1.5.15-universal.zip", "SHA256SUMS.txt"):
        expected = REPO + "/releases/download/macos-v1.5.15-build31/" + asset
        assert expected in page.links, f"Primary Mac download must use the published build31: {entry} {asset}"
    assert REPO + "/releases/download/windows-v1.5.13/HappyLulu-1.5.13-windows-x64-runtime-required.zip" in page.links, entry
assert not any("/downloads/" in urlsplit(link).path for link in links), "Use GitHub release assets"
for path in DIST.rglob("*"):
    assert not path.is_symlink(), path
    assert path.suffix not in {".zip", ".dmg", ".exe", ".p12", ".key"}, path
assert json.loads((ROOT / ".openai/hosting.json").read_text())["project_id"] == "appgprj_6abcb381750c819189cb642ebfa52b3e"
print(f"PASS: {len(pages)} routes, shared section navigation/current pages, direct release downloads, bilingual guides, links/anchors and release assets; no app binaries.")
