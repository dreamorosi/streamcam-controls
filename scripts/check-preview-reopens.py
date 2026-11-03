"""Exercise real panel reopen cycles; save geometry only, never camera frames."""
import argparse
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parent.parent
diagnostic = root / '.build/window-diagnostic.json'
parser = argparse.ArgumentParser()
parser.add_argument('--cycles', type=int, default=6)
parser.add_argument('--existing', action='store_true')
args = parser.parse_args()
if not 1 <= args.cycles <= 100:
    parser.error('--cycles must be between 1 and 100')
if args.existing:
    diagnostic.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'swift', str(root / 'scripts/request-inspection.swift'), 'cycle'], check=True)
    deadline = time.monotonic() + 10
    while not diagnostic.exists():
        if time.monotonic() > deadline:
            raise RuntimeError('App did not open its panel for the comparison')
        time.sleep(0.1)
else:
    subprocess.run(['python3', str(root / 'scripts/check-window.py'), '--launch', '--letterbox'], check=True)
samples = [json.loads(diagnostic.read_text())]
for cycle in range(1, args.cycles + 1):
    diagnostic.unlink()
    subprocess.run(['xcrun', 'swift', str(root / 'scripts/request-inspection.swift'), 'cycle'], check=True)
    deadline = time.monotonic() + 10
    while not diagnostic.exists():
        if time.monotonic() > deadline:
            raise RuntimeError('App did not complete the reopen cycle')
        time.sleep(0.1)
    sample = json.loads(diagnostic.read_text())
    samples.append(sample)
    (root / '.build/reopen-geometry.json').write_text(json.dumps(samples, indent=2))
    layer = sample.get('previewLayer', {})
    image = sample.get('previewVideoRect', {})
    print(f'Cycle {cycle}: layer {layer.get("width")}x{layer.get("height")}, '
          f'video {image.get("width")}x{image.get("height")}, '
          f'renderer generation {sample.get("previewRendererID")}', flush=True)
    if not sample['previewRunning'] or not sample.get('previewConnectionActive'):
        raise RuntimeError('Reopening did not restore the live preview')
baseline = samples[0]['previewVideoRect']
for previous, sample in zip(samples, samples[1:]):
    if sample.get('previewRendererID', 0) <= previous.get('previewRendererID', 0):
        raise SystemExit('FAIL: reopening reused a stale preview renderer')
    image = sample['previewVideoRect']
    if image['width'] < baseline['width'] - 1 or image['height'] < baseline['height'] - 1:
        raise SystemExit('FAIL: displayed image rectangle shrinks with repeated panel reopens')
print('PASS: every reopen used a fresh renderer and stable video geometry. Visual image size still needs the human check.')
