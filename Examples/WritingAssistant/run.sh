#!/bin/bash
# Builds WritingAssistant and launches it as a proper .app bundle.
# Run from the repo root: bash Examples/WritingAssistant/run.sh

set -e
cd "$(dirname "$0")/../.."

echo "Building WritingAssistant..."
xcodebuild -scheme WritingAssistant -destination "platform=macOS" build -quiet

BINARY=$(find ~/Library/Developer/Xcode/DerivedData -name "WritingAssistant" \
    -type f -perm +111 2>/dev/null | grep Build/Products | grep -v ".dSYM" | head -1)

APP=/tmp/WritingAssistant.app
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/WritingAssistant"
cp Examples/WritingAssistant/Info.plist "$APP/Contents/Info.plist"

echo "Launching Writing Assistant..."
open "$APP"
