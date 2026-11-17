#!/bin/zsh
set -eu
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
mkdir -p .cache/native-tests .cache/swift
python3 -m unittest discover -s tests -p 'test_*cli*.py'
TASK_CORE=(NativeTypes.swift NativeZIP.swift NativePPTX.swift NativeStore.swift NativeOllama.swift NativePreviewPolicy.swift)
TASK_SWIFT=(-parse-as-library -import-objc-header NativeBridge.h -lz -lsqlite3 -module-cache-path .cache/swift -swift-version 5)
/usr/bin/swiftc "${TASK_CORE[@]}" tests/NativeCoreTests.swift "${TASK_SWIFT[@]}" -o .cache/native-tests/check
.venv/bin/python tests/native-check.py
.venv/bin/python tests/native-storage-check.py
.venv/bin/python tests/native-preview-privacy-check.py
.venv/bin/python tests/native-zip64-check.py
/usr/bin/swiftc "${TASK_CORE[@]}" NativeEngine.swift tests/NativeEngineTests.swift "${TASK_SWIFT[@]}" -framework PDFKit -framework AppKit -o .cache/native-tests/engine
/usr/bin/swiftc "${TASK_CORE[@]}" NativeEngine.swift tests/NativeLifecycleTests.swift "${TASK_SWIFT[@]}" -framework PDFKit -framework AppKit -o .cache/native-tests/lifecycle
TASK_SCRATCH=$(mktemp -d /tmp/slidelocal-native-suite.XXXXXX)
trap '/bin/rm -rf "$TASK_SCRATCH"' EXIT
.venv/bin/python - "$TASK_SCRATCH/fixture.pptx" <<'PY'
import sys
sys.path.insert(0,'tests')
from make_fixture import make_fixture
make_fixture(sys.argv[1])
PY
.cache/native-tests/engine "$TASK_SCRATCH/queue" "$TASK_SCRATCH/fixture.pptx"
.cache/native-tests/lifecycle "$TASK_SCRATCH/lifecycle" "$TASK_SCRATCH/fixture.pptx"
/usr/bin/swiftc "${TASK_CORE[@]}" NativeEngine.swift tests/NativeReviewRegressions.swift "${TASK_SWIFT[@]}" -framework PDFKit -framework AppKit -o .cache/native-tests/review-regressions
.cache/native-tests/review-regressions "$TASK_SCRATCH/review-orphan" "$TASK_SCRATCH/fixture.pptx" orphan
.cache/native-tests/review-regressions "$TASK_SCRATCH/review-chat" "$TASK_SCRATCH/fixture.pptx" chat
/usr/bin/swiftc NativeTypes.swift NativeStore.swift NativeOllama.swift NativePreviewPolicy.swift tests/NativePrivacyTests.swift "${TASK_SWIFT[@]}" -o .cache/native-tests/privacy
.cache/native-tests/privacy
