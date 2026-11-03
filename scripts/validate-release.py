import json
import os
from pathlib import Path
import plistlib
import subprocess
from release_tools import check_versions, validate_request

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--no-deps', '--locked', '--format-version', '1',
    '--manifest-path', str(root / 'backend/Cargo.toml')
], cwd=root, text=True))
with (root / 'app/Info.plist').open('rb') as file:
    info = plistlib.load(file)
version = check_versions(metadata['packages'][0]['version'], info['CFBundleShortVersionString'])
publishing = validate_request(os.environ['RELEASE_TAG'], os.environ['GITHUB_REF'], version,
    os.environ.get('ACCEPTANCE_CHECKED') == 'true', os.environ.get('TAP_TOKEN_PRESENT') == 'true')
print('Publishing request validated.' if publishing else 'Dry run: no release or tap publication.')
