"""Verify Mac release metadata, localized resources, signatures and archive bytes."""
import hashlib
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from release_delivery import checksums, names, safe_file
root = Path(__file__).resolve().parent.parent
release = Path(sys.argv[1]).resolve()
info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
app = release / 'HappyLulu.app'
assert (app / 'Contents/Info.plist').read_bytes() == (root / 'Resources/Info.plist').read_bytes()
assert (release / 'RELEASE-NOTES.md').read_bytes() == (root / 'RELEASE-NOTES.md').read_bytes()
for resource in [root / 'Resources/HappyLuluBrand.png', *sorted((root / 'Resources/OwlStates').glob('*.png'))]:
    assert (app / 'Contents/Resources' / resource.relative_to(root / 'Resources')).read_bytes() == resource.read_bytes()
for language in ('ko', 'en'):
    assert (app / f'Contents/Resources/{language}.lproj/InfoPlist.strings').read_bytes() == (root / f'Resources/{language}.lproj/InfoPlist.strings').read_bytes()
assert set(subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/HappyLulu')], text=True).split()) == {'arm64', 'x86_64'}
for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
    assert safe_file(release, name).read_bytes() == (root / name).read_bytes()
    assert (app / 'Contents/Resources' / name).read_bytes() == (root / name).read_bytes()
expected_assets = names(info) if (release / 'release.json').exists() else [
    f'HappyLulu-{version}-universal.zip', f'HappyLulu-{version}-universal.dmg',
    'RELEASE-NOTES.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'build-source.json']
checksums(release, expected_assets)

def manifest(bundle):
    result = {}
    for entry in bundle.rglob('*'):
        key = str(entry.relative_to(bundle))
        if entry.is_symlink():
            result[key] = ('link', str(entry.readlink()))
        elif entry.is_file():
            result[key] = ('file', hashlib.sha256(entry.read_bytes()).hexdigest())
    return result
expected = manifest(app)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with tempfile.TemporaryDirectory(prefix='verify-release-', dir=root / 'dist') as temporary:
    temporary = Path(temporary)
    extracted = temporary / 'zip'
    subprocess.run(['ditto', '-x', '-k', str(release / f'HappyLulu-{version}-universal.zip'), str(extracted)], check=True)
    zipped = extracted / 'HappyLulu.app'
    assert manifest(zipped) == expected, 'ZIP differs'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(zipped)], check=True)
    mount = temporary / 'dmg'
    mount.mkdir()
    subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(release / f'HappyLulu-{version}-universal.dmg')], check=True, stdout=subprocess.DEVNULL)
    try:
        mounted = mount / 'HappyLulu.app'
        assert manifest(mounted) == expected, 'DMG differs'
        assert (mount / '시작하기.txt').read_bytes() == (root / 'RELEASE-NOTES.md').read_bytes()
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            assert (mount / name).read_bytes() == (root / name).read_bytes()
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mounted)], check=True)
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
print(f'Mac {version} build {info["CFBundleVersion"]}: metadata, languages, Universal architectures, hashes, ZIP/DMG files and symlinks, signatures verified.')
