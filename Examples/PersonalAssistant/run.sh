#!/bin/bash
# Builds PersonalAssistant and launches it as a proper .app bundle.
# Run from the repo root: bash Examples/PersonalAssistant/run.sh

set -e
cd "$(dirname "$0")/../.."

echo "Building PersonalAssistant..."
xcodebuild -scheme PersonalAssistant -destination "platform=macOS" build -quiet

BINARY=$(find ~/Library/Developer/Xcode/DerivedData -name "PersonalAssistant" \
    -type f -perm +111 2>/dev/null | grep Build/Products | grep -v ".dSYM" | head -1)

APP=/tmp/PersonalAssistant.app
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/PersonalAssistant"
cp Examples/PersonalAssistant/Info.plist "$APP/Contents/Info.plist"

echo "Launching Personal Assistant..."
open "$APP"
