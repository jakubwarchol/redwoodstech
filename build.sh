#!/bin/bash
# Builds RedwoodsTech.app and installs it to /Applications.
# Signed with the Apple Development identity so the Accessibility grant survives rebuilds
# (ad-hoc signatures change every build and macOS would ask again each time).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/RedwoodsTech.app
IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/RedwoodsTech" Sources/*.swift \
  -import-objc-header Sources/Bridging.h \
  -framework Cocoa -framework IOKit -framework ApplicationServices -framework ServiceManagement -framework ColorSync -framework CoreAudio -framework Carbon
cp Info.plist "$APP/Contents/"
cp Resources/menubar-sleeping.svg Resources/menubar-awake.svg "$APP/Contents/Resources/"

# App icon: render the SVG at every iconset size, then pack into .icns
swift scripts/make-iconset.swift Resources/app-icon.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --sign "$IDENTITY" "$APP"

pkill -x RedwoodsTech 2>/dev/null || true
rm -rf /Applications/RedwoodsTech.app
cp -R "$APP" /Applications/
open /Applications/RedwoodsTech.app
echo "Installed /Applications/RedwoodsTech.app"
