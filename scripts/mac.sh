#!/bin/bash
# Build Notes for this Mac (Mac Catalyst) and install it as ~/Applications/Notes.app.
# It's signed to run on this Mac only, so unlike the iPad install it never expires, and without iCloud: only a paid
# team can sign that, so this build keeps its library on the Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Applications/Notes.app"

scripts/board.sh
xcodegen -q
mkdir -p build/mac
entitlements=build/mac/local.entitlements
cp Notes/Mac.entitlements "$entitlements"
for key in icloud-container-identifiers icloud-services ubiquity-container-identifiers; do
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.$key" "$entitlements"
done
xcodebuild -project Notes.xcodeproj -scheme Notes -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/mac -quiet \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    PRODUCT_BUNDLE_IDENTIFIER=com.ashish.Notes PRODUCT_NAME=Notes CODE_SIGN_ENTITLEMENTS="$entitlements" build
# Replace only our own app: Apple's Notes.app lives elsewhere, but never delete something we didn't build.
if [ -d "$APP" ]; then
    [ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = com.ashish.Notes ] || { echo "$APP isn't this app; not replacing it" >&2; exit 1; }
    rm -rf "$APP"
fi
mkdir -p "$HOME/Applications"
ditto build/mac/Build/Products/Release-maccatalyst/Notes.app "$APP"
echo "Installed $APP"
