#!/bin/sh
# Builds Spot Watch (Release) with Xcode 26.6, the last Xcode that installs on
# iOS 15, signs it with the free team (renewing the 7-day profile), and
# installs it on the 6s over USB. Run from anywhere: ios/tools/deploy.sh
set -eu

XCODE26=/Applications/Xcode-26.6.app/Contents/Developer
HERE=$(cd "$(dirname "$0")" && pwd)
IOS=$(dirname "$HERE")
BUILD=${SPOTWATCH_BUILD_DIR:-$IOS/build/dd26}

UDID=${1:-$(/usr/bin/python3 -I "$HERE/install.py" --list | head -1)}
if [ -z "$UDID" ]; then
  echo "No iPhone on USB: plug in the 6s, unlock it, and try again." >&2
  exit 1
fi

DEVELOPER_DIR=$XCODE26 xcodebuild -project "$IOS/SpotWatch.xcodeproj" -scheme SpotWatch \
  -configuration Release -destination "id=$UDID" -destination-timeout 120 \
  -derivedDataPath "$BUILD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -quiet build

/usr/bin/python3 -I "$HERE/install.py" --udid "$UDID" "$BUILD/Build/Products/Release-iphoneos/SpotWatch.app"
