#!/bin/bash
# Converts a GoodNotes backup (folders of .goodnotes files) into this app's notebook format.
#
#   scripts/goodnotes-import.sh BACKUP_DIR             convert into build/goodnotes-import/GoodNotes
#   scripts/goodnotes-import.sh BACKUP_DIR --install   ...and copy that folder into the app on the iPad
#
# Each notebook's page 1 is compared with GoodNotes' own thumbnail; low matches are listed at the end.
# NOTES_DEVICE overrides the target iPad's UDID.
set -euo pipefail
cd "$(dirname "$0")/.."
backup=$(cd "$1" && pwd)
out=build/goodnotes-import
DEVICE="${NOTES_DEVICE:-00008122-001268812633801C}"

SDK=$(xcrun --sdk macosx --show-sdk-path)
SUPPORT="$SDK/System/iOSSupport"
mkdir -p build
# PencilKit crashes in an executable without a bundle identifier, so embed one.
plutil -create xml1 build/goodnotes-import-Info.plist
plutil -insert CFBundleIdentifier -string com.ashish.Notes.goodnotes-import build/goodnotes-import-Info.plist
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-ios17.5-macabi" -sdk "$SDK" \
    -Fsystem "$SUPPORT/System/Library/Frameworks" -I "$SUPPORT/usr/lib/swift" -L "$SUPPORT/usr/lib/swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker build/goodnotes-import-Info.plist \
    Notes/Notebook.swift Notes/Sync.swift Notes/Search.swift Notes/TextBoxes.swift tools/Yjs.swift tools/GoodNotesImport.swift -o build/goodnotes-import-tool

# Unzip every .goodnotes file into a same-named directory, keeping the folder tree.
work=build/goodnotes-unpacked
rm -rf "$out" "$work"
trap 'rm -rf "$work"' EXIT
(cd "$backup" && find . -name '*.goodnotes' -type f) | while IFS= read -r file; do
    mkdir -p "$work/$file"
    ditto -x -k "$backup/$file" "$work/$file"
done
cp "$backup/.goodnotesmeta" "$work/" 2>/dev/null || true # folder colors
build/goodnotes-import-tool "$work" "$out"

if [ "${2:-}" = "--install" ]; then
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
        --domain-identifier com.ashish.Notes --source "$out/GoodNotes" --destination Documents/GoodNotes
fi
