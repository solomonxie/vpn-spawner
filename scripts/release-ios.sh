#!/bin/sh
# Archive a Release build and upload it to App Store Connect in one go.
# Needs: Xcode → Settings → Accounts signed in to the developer Apple ID,
# and Config/Local.xcconfig holding DEVELOPMENT_TEAM.
#
# Build number is a timestamp so every upload is higher than the last;
# the user-visible version is MARKETING_VERSION in project.yml.
#
# Usage: scripts/release-ios.sh [build-number]
set -e
cd "$(dirname "$0")/.."

[ -f Config/Local.xcconfig ] || { echo "Missing Config/Local.xcconfig — cp Config/Local.xcconfig.example Config/Local.xcconfig and set your Team ID"; exit 1; }

SCHEME=VPNSpawner
BUILD=${1:-$(date +%Y%m%d%H%M)}
OUT=/tmp/vpnspawner-release
ARCHIVE=$OUT/$SCHEME-$BUILD.xcarchive

xcodegen generate
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD" archive

xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath "$OUT/export" -allowProvisioningUpdates

echo "Uploaded build $BUILD. Processing in App Store Connect takes 15–60 min."
