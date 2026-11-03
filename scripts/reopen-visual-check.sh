#!/bin/bash
# Human-in-the-loop verdict: renderer metadata alone cannot detect black pixels.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == --record ]]; then
    python3 - "$ROOT/.build/reopen-geometry.json" "$2" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
result = sys.argv[2]
if result not in ['shrinking', 'stable']:
    raise SystemExit('Expected shrinking or stable')
samples = json.loads(path.read_text())
samples[-1]['visualResult'] = result
path.write_text(json.dumps(samples, indent=2))
if result == 'shrinking':
    raise SystemExit('FAIL: the camera image shrinks inside the preview after panel reopens')
print('PASS: user confirmed stable camera image through repeated panel reopens')
PY
    exit
fi
python3 "$ROOT/scripts/check-preview-reopens.py" --existing --cycles 20
printf '\nDid the camera image shrink? Enter shrinking or stable: '
read -r RESULT
bash "$ROOT/scripts/reopen-visual-check.sh" --record "$RESULT"
