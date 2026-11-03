#!/usr/bin/env python3
"""Bounded zoom comparison. Saves control metadata, never images/video."""
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parent.parent
helper = root / '.build/StreamCam Controls.app/Contents/MacOS/streamcam'
report_path = root / '.build/zoom-comparison.json'
device_id = None

if len(sys.argv) == 3 and sys.argv[1] == '--result':
    result = sys.argv[2]
    if result not in ['plateau', 'changes', 'unclear']:
        raise SystemExit('Expected plateau, changes, or unclear')
    report = json.loads(report_path.read_text())
    report['visualResult'] = result
    report_path.write_text(json.dumps(report, indent=2))
    if result == 'plateau':
        print('FAIL: camera accepts higher zoom values but visual zoom stops increasing')
        raise SystemExit(1)
    if result == 'unclear':
        print('INCONCLUSIVE: user could not judge visual zoom')
        raise SystemExit(2)
    print('PASS: visual framing continues changing above 138')
    raise SystemExit(0)

def command(*args):
    identity = ['--device-id', device_id] if device_id else []
    result = subprocess.run([str(helper), *identity, *args], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)

state = command('status')
device_id = state['deviceId']
zoom = state['controls']['zoom']
original = zoom['value']
targets = [100, 138, 200, 400]
for value in targets:
    if not zoom['min'] <= value <= zoom['max'] or (value - zoom['min']) % zoom['step']:
        raise RuntimeError(f'Unsafe comparison value {value}')
report = {'original': original, 'stages': [], 'restored': False}
metadata = root / '.build/window-diagnostic.json'
if metadata.exists():
    report['captureDimensions'] = json.loads(metadata.read_text()).get('videoDimensions')
print(f'Original zoom {original}; comparison sequence 100, 138, 200, 400, then restore.', flush=True)
try:
    for value in targets:
        actual = command('set', 'zoom', str(value))['controls']['zoom']['value']
        report['stages'].append({'requested': value, 'readback': actual})
        report_path.write_text(json.dumps(report, indent=2))
        print(f'Zoom {value}, camera confirms {actual}. Hold 3 seconds.', flush=True)
        if actual != value:
            raise RuntimeError('Camera did not retain the requested zoom')
        time.sleep(3)
finally:
    try:
        actual = command('set', 'zoom', str(original))['controls']['zoom']['value']
        report['restored'] = actual == original
        print(f'Restored zoom {actual}.', flush=True)
        if not report['restored']:
            raise RuntimeError(f'Zoom restoration failed; original value was {original}')
    except Exception as error:
        report['restorationError'] = str(error)
        raise
    finally:
        report_path.write_text(json.dumps(report, indent=2))

print('Control round trip complete. Visual result must be supplied by the user; readback alone is not proof.')
