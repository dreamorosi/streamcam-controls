#!/usr/bin/env python3
"""Own-app geometry/capture check. Does not capture pixels or change settings."""
import json
from pathlib import Path
import os
import signal
import subprocess
import sys
import time

unknown = set(sys.argv[1:]) - {'--launch', '--refresh', '--close', '--letterbox'}
if unknown:
    raise SystemExit('Unknown options: ' + ', '.join(sorted(unknown)))
if '--launch' in sys.argv and '--refresh' in sys.argv:
    raise SystemExit('Choose either --launch or --refresh, not both')
if '--refresh' in sys.argv and '--close' in sys.argv:
    raise SystemExit('--refresh inspects the live panel; use --launch --close for a close test')

root = Path(__file__).resolve().parent.parent
closing = '--close' in sys.argv
path = root / ('.build/window-closed-diagnostic.json' if closing else '.build/window-diagnostic.json')
if '--launch' in sys.argv:
    running = subprocess.run(['pgrep', '-x', 'StreamCamControls'], capture_output=True, text=True)
    for value in running.stdout.split():
        pid = int(value)
        command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'command='], text=True)
        if str(root / '.build/StreamCam Controls.app/Contents/MacOS/StreamCamControls') not in command:
            raise RuntimeError('Refusing to stop a different app')
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 5
    while subprocess.run(['pgrep', '-x', 'StreamCamControls'], capture_output=True).returncode == 0:
        if time.monotonic() > deadline:
            raise RuntimeError('App did not stop')
        time.sleep(0.1)
    subprocess.run([str(root / 'run.sh'), '--build-only'], cwd=root, check=True)
    if path.exists():
        path.unlink()
    arguments = ['open', str(root / '.build/StreamCam Controls.app'), '--args', '--inspect-open']
    if closing:
        arguments.append('--inspect-close')
    subprocess.run(arguments, check=True)
    deadline = time.monotonic() + 15
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError('App did not produce its geometry diagnostic')
        time.sleep(0.1)
elif '--refresh' in sys.argv:
    if path.exists():
        path.unlink()
    subprocess.run(['xcrun', 'swift', str(root / 'scripts/request-inspection.swift')], check=True, timeout=30)
    deadline = time.monotonic() + 5
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Running app did not answer its inspection request')
        time.sleep(0.1)
data = json.loads(path.read_text())
print(json.dumps(data, indent=2))

if closing:
    if data['panelShown'] or data['previewRunning'] or data['sessionRunning'] or data['captureInputs']:
        print('FAIL: camera is still active or retained after closing the panel')
        sys.exit(1)
    print('PASS: closing the panel stops capture and releases its inputs')
    sys.exit(0)

def contained(inner, outer):
    return (inner['width'] > 0 and inner['height'] > 0
            and inner['x'] >= outer['x'] - 1
            and inner['y'] >= outer['y'] - 1
            and inner['x'] + inner['width'] <= outer['x'] + outer['width'] + 1
            and inner['y'] + inner['height'] <= outer['y'] + outer['height'] + 1)

failures = []
if data.get('previewPolicy') != 'shared':
    failures.append('app is not using the selected shared-preview policy')
if 'window' not in data:
    failures.append('camera panel is not open')
else:
    if not contained(data['window'], data['screen']):
        failures.append('window is clipped outside the usable screen')
    if 'preview' not in data or not contained(data['preview'], data['screen']):
        failures.append('preview area is missing or outside the usable screen')
    if not data['movable'] or not (data.get('movableByBackground') or data.get('hasTitleBar')):
        failures.append('window is not movable')
if data['cameraPermission'] != 3:
    failures.append('Camera permission is required for the live-preview check')
elif not data['previewRunning']:
    failures.append('camera authorized but preview did not start')
if data['previewRunning'] and not data.get('previewConnectionActive'):
    failures.append('camera session is running but the preview layer has no active connection')
if data.get('previewLayer', {}).get('width', 0) <= 0 or data.get('previewLayer', {}).get('height', 0) <= 0:
    failures.append('video layer has zero size')
if '--letterbox' in sys.argv:
    if 'previewVideoRect' not in data or not contained(data['previewLayer'], data['previewVideoRect']):
        failures.append('video image does not fill the preview; letterbox bands are visible')
if data.get('videoDimensions') != {'width': 640, 'height': 360}:
    failures.append('capture is not the verified 640x360 full-zoom preview format')
if failures:
    print('FAIL: ' + '; '.join(failures))
    sys.exit(1)
print('PASS: movable panel and preview fit the screen; authorized preview is running')
