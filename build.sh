#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building GroqTalk (Swift)..."

SOURCES=$(find GroqTalk -name "*.swift" | sort)
mkdir -p build

swiftc \
  -o build/GroqTalk \
  -target arm64-apple-macosx13.0 \
  -sdk $(xcrun --show-sdk-path) \
  -O \
  $SOURCES

# Create .app bundle
mkdir -p build/GroqTalk.app/Contents/{MacOS,Resources}
cp build/GroqTalk build/GroqTalk.app/Contents/MacOS/GroqTalk
cp GroqTalk/Resources/Info.plist build/GroqTalk.app/Contents/Info.plist

# Copy icon from Python project if available
if [ -f /Users/ahmed/Desktop/groqtalk/icon.icns ]; then
  cp /Users/ahmed/Desktop/groqtalk/icon.icns build/GroqTalk.app/Contents/Resources/AppIcon.icns
fi

# Code sign with stable identity (preserves Accessibility grant across rebuilds)
codesign --force --sign - \
  --identifier com.groqtalk.app \
  --entitlements GroqTalk/Resources/GroqTalk.entitlements \
  build/GroqTalk.app

echo "Done! App at: build/GroqTalk.app"
echo "Binary size: $(du -h build/GroqTalk.app/Contents/MacOS/GroqTalk | cut -f1)"
echo ""
echo "Run with: open build/GroqTalk.app"
