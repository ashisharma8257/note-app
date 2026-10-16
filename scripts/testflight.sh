#!/bin/bash
# Archive Notes for iPad and Mac with App Store signing and upload both to App Store Connect (the app "draw-note")
# for TestFlight, each with a build number from the time.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/testflight.sh
#
# Set up once, on the team in project.yml:
#   - an App Store Connect API key with the Admin role, saved as ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8;
#   - "Apple Distribution" and "3rd Party Mac Developer Installer" certificates, with their private keys in the login
#     keychain;
#   - App Store provisioning profiles for com.ashishsharma.notes, "draw-note App Store" (iOS) and
#     "draw-note Mac App Store" (Mac Catalyst), in ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
# Signing is manual because Xcode's automatic App Store signing doesn't accept this team's API key ("Cannot verify
# client's JWT headers"); altool, which uploads, does.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_ID=6823127189 # draw-note in App Store Connect; altool can't find the Mac app by bundle id without it
out=build/testflight
build=$(date +%Y%m%d%H%M) # every upload needs a build number of its own

scripts/board.sh
xcodegen -q
rm -rf "$out"
mkdir -p "$out"

# ship DESTINATION PROFILE TYPE: archive, sign and upload one platform; TYPE is altool's (ios or macos).
ship() {
    local archive="$out/$3.xcarchive" options="$out/$3.plist"
    xcodebuild -project Notes.xcodeproj -scheme Notes -configuration Release -destination "generic/platform=$1" \
        -derivedDataPath "$out/dd" -archivePath "$archive" -quiet \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" PROVISIONING_PROFILE_SPECIFIER="$2" \
        CURRENT_PROJECT_VERSION="$build" archive
    plutil -create xml1 "$options"
    plutil -insert method -string app-store-connect "$options"
    plutil -insert signingStyle -string manual "$options"
    plutil -insert signingCertificate -string "Apple Distribution" "$options"
    plutil -insert installerSigningCertificate -string "3rd Party Mac Developer Installer" "$options"
    plutil -insert provisioningProfiles -json "{\"com.ashishsharma.notes\": \"$2\"}" "$options"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" -exportPath "$out/$3"
    xcrun altool --upload-app -f "$(find "$out/$3" -maxdepth 1 \( -name '*.ipa' -o -name '*.pkg' \))" -t "$3" --apple-id "$APP_ID" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}

ship iOS "draw-note App Store" ios
ship 'macOS,variant=Mac Catalyst' "draw-note Mac App Store" macos
echo "Uploaded build $build; it shows in TestFlight once App Store Connect has processed it."
