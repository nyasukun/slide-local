#!/bin/zsh
set -eu
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
mkdir -p .cache/native-tests .cache/swift
/usr/bin/swiftc NativeTypes.swift NativeZIP.swift NativePPTX.swift NativeStore.swift NativeOllama.swift NativePreviewPolicy.swift NativeEngine.swift tests/NativePreviewSmoke.swift -parse-as-library -import-objc-header NativeBridge.h -lz -lsqlite3 -framework AppKit -framework PDFKit -module-cache-path .cache/swift -swift-version 5 -o .cache/native-tests/preview-smoke
.venv/bin/python tests/check-renderer-policy.py
TASK_PREVIEW_CHECK=$(mktemp -d /tmp/slp-preview-test.XXXXXX)
trap '/bin/rm -rf "$TASK_PREVIEW_CHECK"' EXIT
.venv/bin/python - "$TASK_PREVIEW_CHECK/input.pptx" <<'PY'
import sys
from pptx import Presentation
from pptx.util import Inches
r=Presentation();s=r.slides.add_slide(r.slide_layouts[6])
s.shapes.add_textbox(Inches(1),Inches(1),Inches(8),Inches(2)).text='LOCAL PREVIEW TEST — ローカル検証'
r.save(sys.argv[1])
PY
.cache/native-tests/preview-smoke "$TASK_PREVIEW_CHECK/input.pptx" "$TASK_PREVIEW_CHECK/result"
