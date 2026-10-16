#!/bin/bash
# Build Notes, sign it with the free personal team (as com.ashish.Notes, without iCloud), and install it on the iPad.
#
#   scripts/ipad.sh install      build + install now (iPad on USB or same Wi-Fi)
#   scripts/ipad.sh schedule     LaunchAgent that runs the install daily at 21:00
#   scripts/ipad.sh unschedule   remove that LaunchAgent
#
# Free-account installs expire after 7 days; the daily run keeps it renewed.
# NOTES_DEVICE overrides the target iPad's UDID.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
cd "$(dirname "$0")/.."

DEVICE="${NOTES_DEVICE:-00008122-001268812633801C}"
BUNDLE_ID=com.ashish.Notes
TEAM=7M5P7N8BH6
LABEL=com.ashish.notes-install
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/notes-install.log"
STAMP="$HOME/Library/Application Support/notes-install/last-success"

# Xcode reuses a cached profile until it expires, so an install made from it
# expires with it. Drop ours once it has < 3 days left; the build fetches a new one.
renew_profile() {
    local f plist expires
    for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision \
             "$HOME/Library/MobileDevice/Provisioning Profiles"/*.mobileprovision; do
        [ -f "$f" ] || continue
        plist=$(security cms -D -i "$f" 2>/dev/null) || continue
        [[ $(plutil -extract Entitlements.application-identifier raw - <<<"$plist") == *".$BUNDLE_ID" ]] || continue
        expires=$(plutil -extract ExpirationDate raw - <<<"$plist")
        if (( $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expires" +%s) - $(date +%s) < 3 * 86400 )); then
            echo "Profile expires $expires, renewing"
            rm "$f"
        fi
    done
}

install_app() {
    renew_profile
    scripts/board.sh
    xcodegen -q
    mkdir -p build
    plutil -create xml1 build/ipad.entitlements # none: a free team can't sign iCloud
    xcodebuild -project Notes.xcodeproj -scheme Notes -configuration Release \
        -destination "id=$DEVICE" -derivedDataPath build -allowProvisioningUpdates -quiet \
        DEVELOPMENT_TEAM=$TEAM PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID PRODUCT_NAME=Notes CODE_SIGN_ENTITLEMENTS=build/ipad.entitlements build
    xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/Notes.app
    mkdir -p "$(dirname "$STAMP")"
    date +%s > "$STAMP"
}

# Failures are expected when the iPad is away; only nag once the install is close to expiring.
scheduled() {
    echo "=== $(date)"
    "$0" install && return
    local last
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    if (( $(date +%s) - last > 5 * 86400 )); then
        osascript -e 'display notification "No successful install in 5+ days. Connect the iPad and run scripts/ipad.sh install." with title "Notes"'
    fi
}

schedule() {
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$PWD/scripts/ipad.sh</string><string>scheduled</string></array>
    <key>StartCalendarInterval</key><dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Scheduled daily at 21:00. Log: $LOG"
}

unschedule() {
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Unscheduled."
}

case "${1:-}" in
    install) install_app ;;
    scheduled) scheduled ;;
    schedule) schedule ;;
    unschedule) unschedule ;;
    *) echo "usage: $0 install|schedule|unschedule" >&2; exit 2 ;;
esac
