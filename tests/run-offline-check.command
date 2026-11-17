#!/bin/zsh
set -eu
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
mkdir -p .cache/offline-check .cache/native-tests .cache/swift tests/output
.venv/bin/python - <<'PY'
from pathlib import Path
import hashlib,json
s=Path('NativeOllama.swift').read_text();assert s.count('11434')==3
Path('.cache/offline-check/NativeOllama.swift').write_text(s.replace('11434','11435'))
Path('.cache/offline-check/endpoint-change.json').write_text(json.dumps({'production_port':11434,'isolated_test_port':11435,'only_source_change':'three literal port substitutions in test copy; installed app untouched','production_sha256':hashlib.sha256(s.encode()).hexdigest()},indent=2))
PY
TASK_FLAGS=(-parse-as-library -import-objc-header NativeBridge.h -lz -lsqlite3 -framework AppKit -framework PDFKit -module-cache-path .cache/swift -swift-version 5)
TASK_COMMON=(NativeTypes.swift NativeZIP.swift NativePPTX.swift NativeStore.swift NativePreviewPolicy.swift NativeEngine.swift)
/usr/bin/swiftc "${TASK_COMMON[@]}" .cache/offline-check/NativeOllama.swift tests/NativeIntegration.swift "${TASK_FLAGS[@]}" -o .cache/offline-check/integration
/usr/bin/swiftc "${TASK_COMMON[@]}" NativeOllama.swift tests/NativePreviewSmoke.swift "${TASK_FLAGS[@]}" -o .cache/native-tests/preview-smoke
.venv/bin/python tests/check-offline.py
