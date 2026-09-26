#!/usr/bin/env python3
"""Build the self-contained installer. No credentials or runtime state are bundled."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parents[1]
source = (root/'src/install.sh').read_text()
runtime = (root/'src/runtime.sh').read_text().rstrip('\n')
assert source.count('@@RUNTIME@@') == 1
result = source.replace('@@RUNTIME@@', runtime)
(root/'install.sh').write_text(result)
(root/'SHA256SUMS').write_text(hashlib.sha256(result.encode()).hexdigest()+'  install.sh\n')
