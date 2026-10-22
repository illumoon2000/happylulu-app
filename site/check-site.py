"""Validate the source-only marketing site; never fetch or publish releases."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import json
import hashlib
import plistlib
import re

ROOT = Path(__file__).resolve().parent
DIST = ROOT / "dist"
REPO = "https://github.com/young221718/happylulu-app"
with (ROOT.parent / "Resources/Info.plist").open("rb") as source:
    metadata = plistlib.load(source)
MAC_VERSION = metadata["CFBundleShortVersionString"]
MAC_BUILD = metadata["CFBundleVersion"]
MAC_SLUG = f"macos-{MAC_VERSION}"
MAC_TAG = f"macos-v{MAC_VERSION}-build{MAC_BUILD}"
# Release metadata and the approved site assets share one cache version.
ASSET_TAG = f"{MAC_TAG}-site-release-20261022"

# Brand copy is lowercase; literal filenames, URLs and storage paths keep their case.
BRAND_WORD = re.compile(r"(?<![A-Za-z0-9_./\\-])(?:happylulu|lulu)(?![A-Za-z0-9_]|[./\\-][A-Za-z0-9])", re.I)


def check_brand_case(text):
    for match in BRAND_WORD.finditer(text):
        assert match[0] == match[0].lower(), f"Use lowercase brand copy: {text.strip()}"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.elements = []
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
        self.elements.append((tag, fields))
        for name in ("alt", "aria-label", "title", "placeholder"):
            check_brand_case(fields.get(name, ""))
        if tag == "meta" and fields.get("name") == "description":
            check_brand_case(fields.get("content", ""))
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

    def handle_data(self, data):
        check_brand_case(data)

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
releases = {MAC_SLUG: MAC_TAG, "macos-1.5.18": "macos-v1.5.18-build34", "macos-1.5.17": "macos-v1.5.17-build33", "macos-1.5.16": "macos-v1.5.16-build32", "macos-1.5.15": "macos-v1.5.15-build31", "macos-1.5.14": "macos-v1.5.14-build30",
            "windows-1.5.13": "windows-v1.5.13"}
assert len(pages) == 50, "Preserve 48 existing routes and add both Mac 1.5.19 details"
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
    assert list(listing.release_cards) == list(releases), "Show latest Mac, older Macs, then Windows in order"
    for slug, tag in releases.items():
        card = listing.release_cards[slug]
        version = slug.split("-", 1)[1]
        asset = (f"HappyLulu-{version}-universal.dmg" if slug.startswith("macos-")
                 else f"HappyLulu-{version}-windows-x64-runtime-required.zip")
        assert card["changes"] == 3, f"Show key changes without opening the release: {slug}"
        assert REPO + f"/releases/download/{tag}/{asset}" in card["links"], f"Download directly from the release list: {slug}"
        if slug.startswith("macos-"):
            assert REPO + f"/releases/download/{tag}/HappyLulu-{version}-universal.zip" in card["links"], slug
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
mac_download = REPO + f"/releases/download/{MAC_TAG}/HappyLulu-{MAC_VERSION}-universal.dmg"
windows_download = REPO + "/releases/download/windows-v1.5.13/HappyLulu-1.5.13-windows-x64-runtime-required.zip"
for document, page in pages.items():
    header_downloads = [fields for tag, fields in page.elements
                        if tag == "a" and "nav-download" in fields.get("class", "").split()]
    assert len(header_downloads) == 1, document
    header_download = header_downloads[0]
    assert header_download.get("href") == mac_download, f"Header must download the Mac DMG without JavaScript: {document}"
    assert header_download.get("data-windows-download") == windows_download, document
    label = "Windows용 다운로드" if page.language == "ko" else "Download for Windows"
    assert header_download.get("data-windows-label") == label, document
    label = "Mac용 다운로드" if page.language == "ko" else "Download for Mac"
    assert re.search(r'<a class="nav-download"[^>]*>' + re.escape(label) + r'</a>', document.read_text()), document
for home in ("index.html", "en/index.html"):
    document = (DIST / home).resolve()
    page = pages[document]
    assert {"download", "download-title", "windows", "features", "how", "how-title", "calendar", "calendar-faq", "faq", "install",
            "releases", "release-title", "mac-releases", "windows-releases"} <= page.ids, home
    source = document.read_text()
    hero = re.search(r'<div class="hero-actions"[^>]*>(.*?)</div>', source, re.S)
    assert hero, home
    actions = Page()
    actions.feed(hero[0])
    assert actions.links == [mac_download, windows_download], f"Both hero buttons must download directly without JavaScript: {home}"
    assert "download" in actions.ids and "windows" in actions.ids, home
    assert not any("download-card" in fields.get("class", "").split() or "how-section" in fields.get("class", "").split()
                   for tag, fields in page.elements), f"Home keeps downloads and setup compact: {home}"
    assert not any("mobile-download" in fields.get("class", "").split() for tag, fields in page.elements), home
    guide_link = next(fields for tag, fields in page.elements if tag == "a" and fields.get("id") == "how")
    assert guide_link.get("href") == ("/guide/#install" if page.language == "ko" else "/en/guide/#install"), home
    assert ".NET 10 Desktop Runtime x64" in source, f"Windows ZIP runtime requirement stays visible: {home}"
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
    for asset in ("/style.css", "/app.js"):
        references = [link for link in page.links if urlsplit(link).path == asset]
        assert references == [f"{asset}?v={ASSET_TAG}"], f"Shared assets must invalidate the previous release cache: {document} {asset}"
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
    (MAC_TAG, f"HappyLulu-{MAC_VERSION}-universal.dmg"),
    (MAC_TAG, f"HappyLulu-{MAC_VERSION}-universal.zip"),
    ("macos-v1.5.15-build31", "HappyLulu-1.5.15-universal.dmg"),
    ("macos-v1.5.15-build31", "HappyLulu-1.5.15-universal.zip"),
    ("windows-v1.5.13", "HappyLulu-1.5.13-windows-x64-runtime-required.zip"),
]:
    assert REPO + f"/releases/download/{tag}/{asset}" in links, asset
for entry in ("index.html", "en/index.html", "download/index.html"):
    page = pages[(DIST / entry).resolve()]
    assets = (f"HappyLulu-{MAC_VERSION}-universal.dmg",)
    if entry == "download/index.html":
        assets += (f"HappyLulu-{MAC_VERSION}-universal.zip", "SHA256SUMS.txt")
    for asset in assets:
        expected = REPO + f"/releases/download/{MAC_TAG}/" + asset
        assert expected in page.links, f"Primary Mac download must match app metadata: {entry} {asset}"
    assert REPO + "/releases/download/windows-v1.5.13/HappyLulu-1.5.13-windows-x64-runtime-required.zip" in page.links, entry
# Versioned release bodies stay byte-protected; only common shells and badges may change.
# The 1.5.18 baseline is captured before preparing 1.5.19, including its existing brand casing.
historical_release_bodies = {
    'releases/macos-1.5.18/index.html': '32dafc2a26dad805ee1c8b22220f492a3fa80c79229a95dda0ec4652f56d929d',
    'en/releases/macos-1.5.18/index.html': '26e50e846a93dca7796bd9f489f97d463d9fc791412418432f6ee42882a772b0',
    'releases/macos-1.5.17/index.html': '83600dd07884ebfc989e76ba5cb799fff912a96edaca8a3cb84a8850e579f08e',
    'en/releases/macos-1.5.17/index.html': '705b927e590a4f48e5c10858ea769bbb7901a6e60149166a049f3725011ee4c0',
    'releases/macos-1.5.16/index.html': '012904a784abb20ce50af3e9db915b0c8198e254d18abda579eb470633521b81',
    'releases/macos-1.5.15/index.html': 'cf004d42db35717bb12ab639d56a4b15fd6374508132873bf1de079637f7422a',
    'releases/macos-1.5.14/index.html': '14d08f275358f95dee4ee4972ab0aff179d03dcc9b3db013106844d759f60141',
    'releases/windows-1.5.13/index.html': '07e3a30ead8025f1b0ab64218c9eac065dc09f9bab8aee24d3c67ccce499a94b',
    'en/releases/macos-1.5.16/index.html': 'ff3589a27e5db8e1a3f660b0c848f930a698bf7c03964c01b41809e0c4b56de8',
    'en/releases/macos-1.5.15/index.html': 'a1fa5c0f2ebba710464c016ffa2d9a77573c891168604bbbf5649942a863937e',
    'en/releases/macos-1.5.14/index.html': 'f237bf213af0c5ef8d96aa6f7a366faeb4964c93ab220ff562ecb2e0ab720e3b',
    'en/releases/windows-1.5.13/index.html': '50f429c34d17010d0a47daf9d3625a5a2355987eeabe48c2041839f2c75c6ed2',
}
for route, digest in historical_release_bodies.items():
    body = (DIST / route).read_text().split('<div class="docs-article detail-body">', 1)[1].split("\n  <footer", 1)[0]
    assert hashlib.sha256(body.encode()).hexdigest() == digest, f"Preserve historical release body and downloads: {route}"
# Historical Mac badges may change, but the Windows platform statement must stay intact.
for prefix, windows_statement in (("", "Windows 최신 공개 버전은 1.5.13입니다."),
                                   ("en/", "The latest public Windows release remains 1.5.13.")):
    previous = (DIST / prefix / "releases/macos-1.5.15/index.html").read_text()
    assert windows_statement in previous, f"Preserve the Windows platform statement in the historical Mac release: {prefix}"
# Prevent a release bump from leaving the site on the previous binary or menu-bar behavior.
for prefix, phrases in (("", ("퇴근 18:00 · 91분 남음", "즉시", "밀리초·초·분·시·시/분", "1초", "0.1초", "퇴근 예정 시각만")),
                        ("en/", ("Leave 18:00 · 91 min left", "immediately", "milliseconds, seconds, minutes, hours or hours/minutes", "every second", "0.1 seconds", "only the expected departure time"))):
    countdown = (DIST / prefix / "features/countdown/index.html").read_text()
    for phrase in phrases:
        assert phrase in countdown, f"Explain current menu-bar units and cadence: {prefix} {phrase}"
    for route in ("index.html", "guide/index.html", "features/countdown/index.html"):
        document = (DIST / prefix / route).read_text()
        assert f"/{prefix}releases/{MAC_SLUG}/" in document, f"Current release link must match app metadata: {prefix}{route}"
# Describe the new departure visibility preference separately from the countdown unit.
for prefix, phrases in (("", ("메뉴바에 퇴근 예정 시각 표시", "기본은 켜짐", "91분 남음", "퇴근 가능", "재시작", "즉시")),
                        ("en/", ("Show expected departure in menu bar", "on by default", "91 min left", "Ready to leave", "restart", "immediately"))):
    for route in ("features/countdown/index.html", "guide/index.html", f"releases/{MAC_SLUG}/index.html"):
        text = (DIST / prefix / route).read_text()
        for phrase in phrases:
            assert phrase in text, f"Explain departure visibility, ready-to-leave label and saved preference: {prefix}{route} {phrase}"
# The latest release explains the shipped Mac changes and separates install evidence.
for prefix, phrases in (("", ("부엉이 8상태", "다음 날", "승인된 종일", "10분 전부터", "출처 기준 날짜가 끝날 때까지", "15분", "선글라스와 모자", "3열", "활성 입력 필드", "실행 취소", "전체 선택", "윤곽선", "포커스", "캐시", "고정 자체 인증서", "Sparkle", "공증은 적용하지 않았습니다", "Windows 최신 공개 버전은 1.5.13")),
                        ("en/", ("eight owl states", "next day", "approved full-day", "starts 10 minutes before", "source-local midnight", "15 minutes", "sunglasses and a hat", "three columns", "active input field", "Undo, Redo, Cut, Copy, Paste and Select All", "outline", "focus", "cache", "fixed self-signed certificate", "Sparkle", "notarization are not applied", "Windows release remains 1.5.13"))):
    current = (DIST / prefix / f"releases/{MAC_SLUG}/index.html").read_text()
    for phrase in phrases:
        assert phrase in current, f"Explain current Mac changes and limits: {prefix} {phrase}"
for home in ("index.html", "en/index.html"):
    source = (DIST / home).read_text()
    caption = re.search(r"<figcaption>(.*?)</figcaption>", source, re.S)
    assert caption and f"Mac {MAC_VERSION} · build {MAC_BUILD}" in caption[1], f"Preview must match current Mac release: {home}"
    assert "34.5" not in caption[1], f"Remove the previous local preview label: {home}"
assert not any("/downloads/" in urlsplit(link).path for link in links), "Use GitHub release assets"
for path in DIST.rglob("*"):
    assert not path.is_symlink(), path
    assert path.suffix not in {".zip", ".dmg", ".exe", ".p12", ".key"}, path
assert json.loads((ROOT / ".openai/hosting.json").read_text())["project_id"] == "appgprj_6abcb381750c819189cb642ebfa52b3e"
print(f"PASS: {len(pages)} routes, shared section navigation/current pages, direct release downloads, bilingual guides, links/anchors and release assets; no app binaries.")
