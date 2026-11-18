#!/bin/zsh
set -eu
TASK_ROOT="${0:A:h}"
cd "$TASK_ROOT"
mkdir -p .cache/native .cache/swift
/usr/bin/swiftc NativeTypes.swift NativeTranslationPolicy.swift NativeFileDrop.swift NativeZIP.swift NativePPTX.swift NativeStore.swift NativeOllama.swift NativePreviewPolicy.swift NativeEngine.swift NativeApp.swift NativeWorkflowViews.swift -parse-as-library -import-objc-header NativeBridge.h -lz -lsqlite3 -framework PDFKit -framework SwiftUI -framework AppKit -target arm64-apple-macosx14.0 -module-cache-path .cache/swift -swift-version 5 -O -whole-module-optimization -Xlinker -dead_strip -o .cache/native/SlideLocal
TASK_BUNDLE='.cache/native/Slide Local.app'
mkdir -p "$TASK_BUNDLE/Contents/MacOS" "$TASK_BUNDLE/Contents/Resources"
cp AppInfo.plist "$TASK_BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$TASK_BUNDLE/Contents/Resources/AppIcon.icns"
cp .cache/native/SlideLocal "$TASK_BUNDLE/Contents/MacOS/SlideLocal"
/usr/bin/codesign --force --deep --sign - "$TASK_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$TASK_BUNDLE"
if [[ "${1:-}" != '--stage' ]]; then
    mkdir -p 'Slide Local.app/Contents/MacOS' 'Slide Local.app/Contents/Resources'
    cp AppInfo.plist 'Slide Local.app/Contents/Info.plist'
    cp AppIcon.icns 'Slide Local.app/Contents/Resources/AppIcon.icns'
    cp .cache/native/SlideLocal 'Slide Local.app/Contents/MacOS/SlideLocal.next'
    mv -f 'Slide Local.app/Contents/MacOS/SlideLocal.next' 'Slide Local.app/Contents/MacOS/SlideLocal'
    /usr/bin/codesign --force --deep --sign - 'Slide Local.app'
    /usr/bin/codesign --verify --deep --strict 'Slide Local.app'
fi
print 'Slide Local 2.0.5 をビルドしました。'
