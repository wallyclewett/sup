#!/bin/zsh
# Build Sup.app from the files in Sources/ and install it to ~/Applications.
set -e
here=${0:a:h}
app=~/Applications/Sup.app

# Quit the running copy and start from an empty app folder.
pkill -x Sup || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Info.plist, with a new build number each time, so macOS (and Notification Centre) reload the icon.
cp "$here/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$app/Contents/Info.plist"

# App icon: compile the asset catalog into Assets.car and AppIcon.icns, the same as an Xcode build.
xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist /dev/null "$here/Assets.xcassets" >/dev/null

# Compile every Swift file in Sources/ into one program.
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos14 \
    "$here"/Sources/*.swift -o "$app/Contents/MacOS/Sup"

# Sign it "ad hoc" (no developer account needed), so macOS lets it use Bluetooth and notifications.
codesign --force --sign - "$app"
touch "$app"
echo "Built $app"
open "$app"
