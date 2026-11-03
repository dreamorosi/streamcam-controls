"""Don't overwrite a running bundle; allow independent packaging builds."""
from pathlib import Path
import subprocess
import sys

target = str(Path(sys.argv[1]).resolve())
result = subprocess.run(['pgrep', '-x', 'StreamCamControls'], text=True, capture_output=True)
for pid in result.stdout.split():
    process = subprocess.run(['ps', '-p', pid, '-o', 'command='], text=True, capture_output=True)
    command = process.stdout.strip()
    if command == target or command.startswith(target + ' '):
        raise SystemExit('Quit the app using this build target before rebuilding it.')
