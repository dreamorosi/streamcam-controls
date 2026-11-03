#!/usr/bin/env python3
"""Build a separate app and DMG without launching or replacing the running app."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from release_tools import archive_name, check_versions, render_cask

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--no-deps', '--locked', '--format-version', '1',
    '--manifest-path', str(root / 'backend/Cargo.toml')
], cwd=root, text=True))
with (root / 'app/Info.plist').open('rb') as file:
    info = plistlib.load(file)
version = check_versions(metadata['packages'][0]['version'], info['CFBundleShortVersionString'])
build = root / '.build/release-build'
output = root / '.build/releases'
output.mkdir(parents=True, exist_ok=True)
subprocess.run([str(root / 'run.sh'), '--build-only'], cwd=root,
               env=dict(os.environ, STREAMCAM_BUILD_DIR=str(build)), check=True)
app = build / 'StreamCam Controls.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
cli = app / 'Contents/MacOS/streamcam'
actual = subprocess.check_output([str(cli), '--version'], text=True).strip()
if actual != f'streamcam {version}':
    raise SystemExit('Bundled CLI version does not match the app')
dmg = output / archive_name(version)
with tempfile.TemporaryDirectory(prefix='dmg-stage-', dir=root / '.build') as temporary:
    staging = Path(temporary)
    subprocess.run(['ditto', str(app), str(staging / app.name)], check=True)
    (staging / 'Applications').symlink_to('/Applications')
    subprocess.run(['hdiutil', 'create', '-ov', '-volname', 'StreamCam Controls',
                    '-srcfolder', str(staging), '-format', 'UDZO', str(dmg)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(dmg)], check=True)
subprocess.run(['codesign', '--verify', str(dmg)], check=True)
subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
mount = Path(tempfile.mkdtemp(prefix='dmg-inspect-', dir=root / '.build'))
attached = False
try:
    subprocess.run(['hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse', '-mountpoint', str(mount)],
                   check=True, capture_output=True)
    attached = True
    mounted_app = mount / app.name
    if not (mount / 'Applications').is_symlink():
        raise RuntimeError('DMG is missing its Applications link')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(mounted_app)], check=True)
    mounted_version = subprocess.check_output([
        str(mounted_app / 'Contents/MacOS/streamcam'), '--version'
    ], text=True).strip()
    if mounted_version != actual:
        raise RuntimeError('DMG does not contain the expected CLI')
    for name in ['LICENSE', 'ThirdPartyNotices.txt', 'AppIcon.icns']:
        if not (mounted_app / 'Contents/Resources' / name).is_file():
            raise RuntimeError('DMG is missing a required resource: ' + name)
finally:
    if attached:
        # If detaching fails, preserve the mount point. Never recursively remove
        # a directory that might still contain mounted distribution media.
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True)
    mount.rmdir()
digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
checksum = dmg.with_suffix('.dmg.sha256')
checksum.write_text(f'{digest}  {dmg.name}\n')
cask = output / 'streamcam-controls.rb'
cask.write_text(render_cask(version, digest))
manifest = {'version': version, 'dmg': dmg.name, 'checksum': checksum.name,
            'cask': cask.name, 'sha256': digest}
(output / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Packaged {dmg}. No app was launched; no release or tap was published.')
