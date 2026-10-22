#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift --version
xcrun --show-sdk-version
swift build --build-system native --product HappyLulu
build_dir="$(swift build --build-system native --show-bin-path)"
python3 - "$build_dir" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys, tempfile
build = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='HappyLulu-runtime-profile-') as temporary:
    root = pathlib.Path(temporary)
    for identifier, development in [('local.chanyoung.AfterSix', False),
                                    ('local.chanyoung.HappyLulu.Dev.manual-leave.20261015', True),
                                    ('test.happylulu.qa', True)]:
        app = root / (identifier + '.app')
        executable = app / 'Contents/MacOS/HappyLulu'
        executable.parent.mkdir(parents=True)
        shutil.copy2(build / 'HappyLulu', executable)
        with (app / 'Contents/Info.plist').open('wb') as target:
            plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'HappyLulu',
                          'CFBundlePackageType': 'APPL'}, target)
        environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(build))
        result = subprocess.run([str(executable), '--runtime-profile'], env=environment,
                                check=True, text=True, capture_output=True)
        values = dict(line.split('=', 1) for line in result.stdout.splitlines())
        assert values['development'] == str(development).lower(), result.stdout
        for gate in ['externalIntegrations', 'loginItemChanges', 'automaticActivity']:
            assert values[gate] == str(not development).lower(), result.stdout
        for store in ['state', 'routing', 'catalog', 'sync']:
            assert ('/HappyLulu Dev/' in values[store]) == development, result.stdout
        if development:
            blocked = subprocess.run([str(executable), '--calendar-preview'], env=environment,
                                     text=True, capture_output=True)
            assert blocked.returncode == 64, blocked
    print('PASS packaged production/Dev/QA composition profiles, isolated stores and blocked Dev calendar CLI')
PY
