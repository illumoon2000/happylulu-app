#!/usr/bin/env python3
"""Manual curl proof of the Daouoffice web API, with human CAPTCHA input.

No automatic credential retries. A second login is possible only after human
CAPTCHA input in the web-flow mode. Passwords travel only through curl stdin;
cookies live in a private temporary directory and are deleted on exit.
The saved report contains response shapes, counts and status flags, never personal values.
"""
import argparse
import base64
import calendar
from datetime import datetime
import getpass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.parse
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent.parent
REPORT = ROOT / ".build/daouoffice-curl-report.json"
os.umask(0o077)


def shape(value, depth=0):
    if isinstance(value, dict):
        return {key: shape(item, depth + 1) for key, item in list(value.items())[:60]
                if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", key)} if depth < 5 else "object"
    if isinstance(value, list):
        return {"count": len(value), "firstFields": shape(value[0], depth + 1) if value else None}
    if value is None:
        return "null"
    return type(value).__name__


def saved_password(config_path):
    # Read only the feature's own Keychain item, without printing its value.
    script = r'''
import Foundation
import CryptoKit
import Security
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let data = try JSONEncoder().encode([value["baseURL"] as! String, value["loginID"] as! String])
let account = "daouoffice." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
 kSecAttrService as String: "local.chanyoung.AfterSix.Plugins.DaouOffice",
 kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
var item: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
 let bytes = item as? Data, let password = String(data: bytes, encoding: .utf8) else { exit(2) }
FileHandle.standardOutput.write(try JSONEncoder().encode(["password": password]))
'''
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / ".build/clang-module-cache"))
    result = subprocess.run(["swift", "-e", script, str(config_path)], capture_output=True, env=env, timeout=60)
    if result.returncode:
        raise RuntimeError("Could not read the saved Keychain credential; no login was attempted.")
    return json.loads(result.stdout)["password"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    secret_mode = parser.add_mutually_exclusive_group(required=True)
    secret_mode.add_argument("--prompt-password", action="store_true", help="Enter a password in the terminal with echo disabled")
    secret_mode.add_argument("--use-saved", action="store_true", help="Use the app's existing Keychain credential")
    challenge_mode = parser.add_mutually_exclusive_group()
    challenge_mode.add_argument("--captcha", action="store_true", help="Fetch a CAPTCHA before one manual login")
    challenge_mode.add_argument("--login-then-captcha", action="store_true",
                                help="Match the web flow: one login, then human CAPTCHA input only if requested")
    parser.add_argument("--agent-captcha", action="store_true",
                        help="Print the CAPTCHA image path for a human viewer without opening Preview; requires --use-saved --login-then-captcha and a PTY")
    parser.add_argument("--config", type=Path, default=Path.home() / "Library/Application Support/AfterSix/Plugins/daouoffice.json")
    args = parser.parse_args()
    if args.agent_captcha:
        if not (args.use_saved and args.login_then_captcha):
            parser.error("--agent-captcha requires --use-saved --login-then-captcha")
        if not sys.stdin.isatty():
            parser.error("--agent-captcha requires an interactive terminal (PTY) for human input")
    config = json.loads(args.config.read_text())
    base = config["baseURL"].rstrip("/")
    parts = urllib.parse.urlparse(base)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise RuntimeError("The saved company address must be a base HTTPS address.")
    report = {"startedAt": datetime.now(ZoneInfo("Asia/Seoul")).isoformat(), "success": False, "steps": []}
    password = None
    captcha = ""
    try:
        if args.prompt_password:
            if not sys.stdin.isatty():
                raise RuntimeError("Use an interactive terminal for hidden password input.")
            password = getpass.getpass("Daouoffice password (hidden): ")
        else:
            password = saved_password(args.config)
        if not password:
            raise RuntimeError("No password entered; no login was attempted.")
        with tempfile.TemporaryDirectory(prefix="happylulu-curl-", dir="/tmp") as folder:
            cookie = str(Path(folder) / "session.cookies")

            def session_cookies():
                # Compare the session in memory; never print cookie names or values.
                if not Path(cookie).exists():
                    return set()
                rows = set()
                for line in Path(cookie).read_text().splitlines():
                    if line.startswith("#HttpOnly_"):
                        line = line[len("#HttpOnly_"):]
                    elif line.startswith("#"):
                        continue
                    fields = line.split("\t")
                    if len(fields) == 7:
                        rows.add(tuple(fields))
                return rows

            captcha_cookies = None

            def request(path, body=None, method="GET", login=False, expect_json=True, allow_captcha_challenge=False):
                cookies_before = session_cookies()
                command = ["curl", "--silent", "--show-error", "--max-time", "25", "--proto", "=https",
                           "--cookie-jar", cookie, "--cookie", cookie, "--request", method,
                           "--header", "Accept: application/json", "--header", "Content-Type: application/json",
                           "--header", "X-Referer-Info;" if login else "X-Referer-Info: " + parts.hostname,
                           "--header", "Referer: " + base + "/login", "--header", "Origin: " + base,
                           "--write-out", "\n__CURL_META__%{http_code} %{content_type}"]
                if body is not None:
                    command += ["--data-binary", "@-"]
                command += [base + path]
                result = subprocess.run(command, input=json.dumps(body, ensure_ascii=False).encode() if body is not None else None,
                                        capture_output=True, timeout=30)
                if result.returncode:
                    raise RuntimeError("curl failed; no automatic retry was made.")
                raw, meta = result.stdout.rsplit(b"\n__CURL_META__", 1)
                status = int(meta.split(b" ", 1)[0])
                content_type = meta.split(b" ", 1)[1].decode()
                try:
                    payload = json.loads(raw)
                except ValueError:
                    payload = None
                code = payload.get("code") if isinstance(payload, dict) else None
                step = {"path": re.sub(r"/\d+(?=/|$)", "/{id}", path.split("?")[0]), "http": status,
                        "contentType": content_type, "shape": shape(payload),
                        "cookieCountBefore": len(cookies_before), "cookieCountAfter": len(session_cookies())}
                if login and captcha_cookies:
                    # Jar continuity alone does not prove the server accepted a cookie.
                    step["captchaCookieJarEntriesRetained"] = captcha_cookies.issubset(cookies_before)
                if isinstance(payload, dict) and isinstance(payload.get("data"), dict):
                    refresh = payload["data"].get("needCaptchaRequest")
                    if isinstance(refresh, bool):
                        step["captchaRefreshRequired"] = refresh
                if isinstance(code, str) and re.fullmatch(r"[A-Z0-9_-]{1,40}", code):
                    step["code"] = code
                report["steps"].append(step)
                print(json.dumps(step, ensure_ascii=False), flush=True)
                # Some gateway errors use HTTP 200. They are still failed API requests.
                service_error = isinstance(code, str) and re.match(r"^(PORTAL|ROUTE)-", code)
                if not 200 <= status < 300 or service_error:
                    if login and isinstance(payload, dict) and isinstance(payload.get("message"), str):
                        message = payload["message"]
                        secrets = [password, config["loginID"], captcha]
                        secrets += [row[-1] for row in cookies_before | session_cookies()]
                        for secret in secrets:
                            if secret:
                                message = message.replace(secret, "[redacted]")
                        message = " ".join(message.split())[:300]
                        print("Server message (not saved): " + message, file=sys.stderr, flush=True)
                    if allow_captcha_challenge and status == 400 and code in ("PORTAL-0003", "PORTAL-0005", "PORTAL-0012"):
                        return {"humanCaptchaRequired": True}
                    raise RuntimeError("Request rejected (" + str(status) + (" / " + step["code"] if "code" in step else "") +
                                       "). Stopped without retrying.")
                if expect_json and payload is None:
                    raise RuntimeError("The API returned non-JSON content.")
                return payload

            request("/login", expect_json=False)
            companies = request("/api/portal/public/auth/company")["data"]["companyList"]
            if len(companies) != 1:
                raise RuntimeError("Company selection is required.")
            company_id = companies[0]["companyId"]

            def login_request(allow_captcha_challenge=False):
                return request("/api/portal/public/auth/login", body={"companyId": company_id, "loginId": config["loginID"],
                               "password": password, "captcha": captcha, "locale": "ko"}, method="POST", login=True,
                               allow_captcha_challenge=allow_captcha_challenge)

            login_succeeded = False
            needs_captcha = args.captcha
            if args.login_then_captcha:
                initial = login_request(allow_captcha_challenge=True)
                needs_captcha = isinstance(initial, dict) and initial.get("humanCaptchaRequired") is True
                login_succeeded = not needs_captcha
            if needs_captcha:
                challenge = request("/api/portal/public/auth/captcha", body={"loginId": config["loginID"], "companyId": company_id}, method="PUT")
                encoded = challenge["data"]["captchaImage"]
                if encoded.startswith("data:image/png;base64,"):
                    encoded = encoded.split(",", 1)[1]
                image = base64.b64decode(encoded, validate=True)
                if not image.startswith(b"\x89PNG\r\n\x1a\n") or len(image) > 512 * 1024:
                    raise RuntimeError("Unexpected CAPTCHA image format; no login was attempted.")
                # A unique path prevents Preview from displaying a previous challenge.
                captcha_path = Path(folder) / "captcha.png"
                captcha_path.write_bytes(image)
                captcha_path.chmod(0o600)
                captcha_cookies = session_cookies()
                print("CAPTCHA image: " + str(captcha_path), flush=True)
                # The human running this command views and solves the image. No model/solver is called.
                if not args.agent_captcha:
                    subprocess.run(["open", str(captcha_path)], check=False)
                captcha = input("Enter the CAPTCHA shown in the image (Enter submits one login; Ctrl-C cancels): ").strip()
                if not captcha:
                    raise RuntimeError("CAPTCHA was left blank; no login was attempted.")
            if not login_succeeded:
                login_request()
            password = None
            now = datetime.now(ZoneInfo("Asia/Seoul"))
            summary = request("/api/leave/normal/my/annual/summary")
            upcoming = request("/api/leave/normal/my/upcoming")
            past = request("/api/leave/normal/my/past/" + str(now.year))
            session = request("/gw/api/user/session")
            user_id = str(session["data"]["id"])
            if not user_id.isdigit():
                raise RuntimeError("Unexpected user identifier.")
            calendars = request("/gw/api/calendar/user/" + user_id + "/calendar")
            days = calendar.monthrange(now.year, now.month)[1]
            query = [("timeMin", f"{now.year:04}-{now.month:02}-01T00:00:00.000+09:00"),
                     ("timeMax", f"{now.year:04}-{now.month:02}-{days:02}T23:59:59.999+09:00"),
                     ("includingAttendees", "false")]
            ids = [str(item["id"]) for item in calendars["data"]]
            if any(not value.isdigit() for value in ids):
                raise RuntimeError("Unexpected calendar identifier.")
            query += [("calendarIds[]", value) for value in ids]
            events = request("/gw/api/calendar/event?" + urllib.parse.urlencode(query)) if ids else {"data": []}
            report["counts"] = {"upcomingLeave": len(upcoming["data"]["elements"]),
                                "pastLeave": len(past["data"]["elements"]), "calendars": len(ids), "events": len(events["data"])}
            # Check the documented summary fields exist without reporting their personal values.
            if not all(key in summary["data"] for key in ("totalDays", "usedDays", "formattedRemain")):
                raise RuntimeError("Unexpected annual summary fields; inspect the response shape report.")
            report["success"] = True
            print("PASS curl: login and all leave/calendar requests returned successful JSON responses.", flush=True)
    except (RuntimeError, KeyError, TypeError, ValueError, subprocess.TimeoutExpired) as error:
        # Only local error text and a redacted service message can reach the terminal.
        report["failureType"] = type(error).__name__
        if isinstance(error, RuntimeError):
            print(str(error), file=sys.stderr)
        else:
            print("Unexpected response or interrupted command; stopped without retrying.", file=sys.stderr)
    except (KeyboardInterrupt, EOFError):
        report["failureType"] = "cancelled"
        print("Cancelled; no automatic retry.", file=sys.stderr)
    finally:
        password = None
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        REPORT.chmod(0o600)
        print("Report (shapes, counts and status flags only): " + str(REPORT), flush=True)
    return 0 if report["success"] else 1


if __name__ == "__main__":
    sys.exit(main())
