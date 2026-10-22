#!/usr/bin/env python3
"""Real Sparkle update on a unique, data-free signed fixture. Never publishes."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
HOME = Path.home()
TOKEN = uuid.uuid4().hex
DOMAIN = 'local.happylulu.signed-auto-probe.' + TOKEN
FIXTURE = Path(tempfile.mkdtemp(prefix='HappyLulu-signed-auto-' + TOKEN + '-'))
STAGE = 'initializing'
REQUESTS = []
SERVER = None
PASSED = False


def command(args, *, output=None):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, capture_output=True, text=True)
    if output:
        Path(output).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError('command failed at ' + STAGE + '; see retained fixture logs')
    return result.stdout + result.stderr


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def protected_snapshot():
    app = HOME / 'Applications/happylulu.app'
    attendance_roots = [HOME / 'Library/Application Support/AfterSix', HOME / 'Library/Application Support/HappyLulu']
    attendance = {}
    state_file = HOME / 'Library/Application Support/AfterSix/state.json'
    attendance[str(state_file)] = sha(state_file)
    for root in attendance_roots:
        if root.exists():
            for file in root.rglob('*'):
                if file.is_file() and ('attendance' in file.name.lower() or file.name == 'settings.json'):
                    attendance[str(file)] = sha(file)
    database = HOME / 'Library/Application Support/HappyLulu/CalendarSync/sync.sqlite'
    state = None
    if database.is_file():
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
            row = connection.execute('SELECT document FROM state WHERE id = 1').fetchone()
            if row:
                document = row[0].encode() if isinstance(row[0], str) else row[0]
                state = hashlib.sha256(document).hexdigest()
    bundle = {str(file.relative_to(app)): sha(file) for file in app.rglob('*') if file.is_file()} if app.exists() else {}
    return {'productionBundle': bundle, 'attendance': attendance, 'calendarDocument': state}


def events():
    log = FIXTURE / 'launch.jsonl'
    if not log.exists():
        return []
    result = []
    for line in log.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result


def owned_process_alive(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
    return result.returncode == 0 and str(FIXTURE) in result.stdout


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(FIXTURE / 'updates'), **kwargs)

    def do_GET(self):
        REQUESTS.append(self.path)
        super().do_GET()

    def log_message(self, fmt, *args):
        with (FIXTURE / 'http.log').open('a') as file:
            file.write((fmt % args) + '\n')


before = protected_snapshot()
try:
    STAGE = 'require-fixed-signing-identity'
    identity = HOME / 'Library/Application Support/HappyLulu/Signing/identity.json'
    if not identity.is_file() or not json.loads(identity.read_text()).get('sha1'):
        raise RuntimeError('fixed signing identity is not configured')
    frameworks = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64'
    generator = ROOT / '.build/artifacts/sparkle/Sparkle/bin/generate_appcast'
    installed = FIXTURE / 'Installed/SigningProbe.app'
    candidate = FIXTURE / 'Candidate/SigningProbe.app'
    updates = FIXTURE / 'updates'
    updates.mkdir()
    (FIXTURE / 'launch.jsonl').touch(mode=0o600)
    SERVER = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    port = SERVER.server_address[1]
    threading.Thread(target=SERVER.serve_forever, daemon=True).start()
    original = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    info = {key: original[key] for key in original if key.startswith('SU') or key == 'HappyLuluUpdateServiceEnabled'}
    info.update(CFBundleIdentifier=DOMAIN, CFBundleExecutable='SigningProbe', CFBundleName='SigningProbe',
                CFBundlePackageType='APPL', CFBundleShortVersionString='1', CFBundleVersion='1',
                LSMinimumSystemVersion='13.0', LSUIElement=True,
                SigningProbeLogPath=str(FIXTURE / 'launch.jsonl'),
                SUFeedURL=f'http://127.0.0.1:{port}/appcast.xml',
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    STAGE = 'compile-data-free-probe'
    (installed / 'Contents/MacOS').mkdir(parents=True)
    (installed / 'Contents/Resources').mkdir()
    command(['swiftc', '-swift-version', '6', '-F', frameworks,
             '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
             ROOT / 'Sources/AfterSix/AppUpdater.swift', ROOT / 'Tests/SigningUpdateProbe/main.swift',
             '-o', installed / 'Contents/MacOS/SigningProbe'], output=FIXTURE / 'compile.log')
    (installed / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (installed / 'Contents/Resources/probe-version.txt').write_text('version-one')
    command(['bash', ROOT / 'scripts/embed-sparkle.sh', installed], output=FIXTURE / 'embed.log')
    shutil.copytree(installed, candidate, symlinks=True)
    candidate_info = dict(info, CFBundleShortVersionString='2', CFBundleVersion='2')
    (candidate / 'Contents/Info.plist').write_bytes(plistlib.dumps(candidate_info))
    (candidate / 'Contents/Resources/probe-version.txt').write_text('version-two')
    STAGE = 'sign-fixtures'
    for app, name in [(installed, 'installed'), (candidate, 'candidate')]:
        command(['bash', ROOT / 'scripts/sign-app.sh', app], output=FIXTURE / (name + '-sign.log'))
    before_requirement = command(['codesign', '-d', '-r-', installed], output=FIXTURE / 'requirement-before.log')
    candidate_requirement = command(['codesign', '-d', '-r-', candidate], output=FIXTURE / 'requirement-candidate.log')
    def requirement(text):
        return next(line for line in text.splitlines() if line.startswith('designated =>'))
    if requirement(before_requirement) != requirement(candidate_requirement):
        raise RuntimeError('fixture designated requirements differ')
    STAGE = 'generate-eddsa-signed-local-feed'
    archive = updates / 'SigningProbe-2.zip'
    command(['ditto', '-c', '-k', '--keepParent', candidate, archive], output=FIXTURE / 'archive.log')
    command([generator, '--account', 'happylulu-updates', '--download-url-prefix', f'http://127.0.0.1:{port}/',
             '--maximum-deltas', '0', updates], output=FIXTURE / 'appcast-generation.log')
    feed = updates / 'appcast.xml'
    enclosure = ET.parse(feed).find('.//enclosure')
    if enclosure is None or not enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'):
        raise RuntimeError('generated archive signature missing')
    STAGE = 'automatic-background-download-install-relaunch'
    command(['open', '-n', '-g', installed], output=FIXTURE / 'open.log')
    deadline = time.monotonic() + 110
    while time.monotonic() < deadline:
        if any(item['stage'] == 'updatedRelaunch' and item['version'] == '2' for item in events()):
            break
        time.sleep(0.5)
    else:
        raise RuntimeError('automatic update did not relaunch version 2 before bounded timeout')
    STAGE = 'verify-replaced-app-and-processes'
    log = events()
    first = next(item for item in log if item['stage'] == 'launched' and item['version'] == '1')
    second = next(item for item in log if item['stage'] == 'launched' and item['version'] == '2')
    if not any(item['stage'] == 'updaterState' and item.get('checks') and item.get('downloads') for item in log):
        raise RuntimeError('automatic check/download preferences were not active')
    if not any(item['stage'] == 'willTerminate' and item['pid'] == first['pid'] for item in log):
        raise RuntimeError('original app termination callback was not observed')
    if first['pid'] == second['pid'] or owned_process_alive(first['pid']):
        raise RuntimeError('old PID did not exit before version 2 relaunch')
    if second['resource'] != 'version-two':
        raise RuntimeError('relaunch did not read new candidate resource')
    if not any(path.startswith('/appcast.xml') for path in REQUESTS) or '/SigningProbe-2.zip' not in REQUESTS:
        raise RuntimeError('feed/archive HTTP requests not both observed')
    actual_info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
    if actual_info['CFBundleVersion'] != '2':
        raise RuntimeError('installed app version was not replaced')
    command(['codesign', '--verify', '--deep', '--strict', installed], output=FIXTURE / 'updated-verify.log')
    after_requirement = command(['codesign', '-d', '-r-', installed], output=FIXTURE / 'requirement-after.log')
    if requirement(before_requirement) != requirement(after_requirement):
        raise RuntimeError('update changed designated requirement')
    STAGE = 'verify-production-preserved'
    after = protected_snapshot()
    if before != after:
        raise RuntimeError('production app or personal state changed during isolated fixture')
    report = {'result': 'passed', 'automaticFeedFetch': True, 'automaticArchiveFetch': True,
              'installedVersion': '2', 'oldProcessExited': True, 'newProcessLaunched': True,
              'updatedResource': True, 'deepSignatureVerified': True, 'designatedRequirementPreserved': True,
              'productionAppAndPersonalStatePreserved': True, 'publicPublication': False}
    (FIXTURE / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, sort_keys=True))
    PASSED = True
except Exception as error:
    after = protected_snapshot()
    report = {'result': 'failed', 'stage': STAGE, 'reason': str(error), 'fixtureEvidence': str(FIXTURE),
              'productionAppAndPersonalStatePreserved': before == after,
              'observedLaunchStages': [item.get('stage') for item in events()], 'httpRequests': REQUESTS}
    (FIXTURE / 'result.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, sort_keys=True))
finally:
    if SERVER:
        SERVER.shutdown()
        SERVER.server_close()
    for item in events():
        pid = item.get('pid')
        if isinstance(pid, int) and owned_process_alive(pid):
            os.kill(pid, signal.SIGTERM)
    subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
    cache = HOME / 'Library/Caches' / DOMAIN
    if cache.exists() and not cache.is_symlink():
        shutil.rmtree(cache)
    if PASSED:
        shutil.rmtree(FIXTURE)
if not PASSED:
    sys.exit(1)
