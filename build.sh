#!/bin/zsh
# Build Sup.app and install it to ~/Applications.
set -e
here=${0:a:h}
app=~/Applications/Sup.app

pkill -x Sup || true
pkill -x StandUp || true            # the old name
rm -rf ~/Applications/StandUp.app   # the old name
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
# A new build number each time, so macOS (and Notification Centre) reload the icon
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
# App icon: an asset catalog (Assets.car) plus AppIcon.icns, the same as an Xcode build
xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist /dev/null "$here/Assets.xcassets" >/dev/null
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14 \
    "$here/main.swift" -o "$app/Contents/MacOS/Sup"
codesign --force --sign - "$app"
touch "$app"   # so Finder and notifications pick up a new icon
echo "Built $app"
open "$app"
