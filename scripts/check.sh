#!/bin/bash
# Builds Tests/NotebookCheck.swift with Notes/Notebook.swift and Notes/Shapes.swift as a Mac Catalyst command-line tool and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
SUPPORT="$SDK/System/iOSSupport"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# PencilKit crashes in an executable without a bundle identifier, so embed one.
plutil -create xml1 "$out/Info.plist"
plutil -insert CFBundleIdentifier -string com.ashish.Notes.check "$out/Info.plist"
xcrun swiftc -swift-version 5 -parse-as-library -Onone -target "$(uname -m)-apple-ios26.0-macabi" -sdk "$SDK" \
    -Fsystem "$SUPPORT/System/Library/Frameworks" -I "$SUPPORT/usr/lib/swift" -L "$SUPPORT/usr/lib/swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" \
    Notes/Notebook.swift Notes/Shapes.swift Tests/NotebookCheck.swift -o "$out/check"
"$out/check"
