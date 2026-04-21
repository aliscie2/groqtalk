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

# Code-sign with a stable self-signed identity so macOS TCC (Accessibility,
# Input Monitoring) keeps the user's grant across rebuilds. Ad-hoc signing
# (-s -) mints a new cdhash every build, TCC treats it as a different app,
# and the user has to re-grant after every build.
#
# One-time setup: run scripts/create-signing-cert.sh.
SIGN_ID="GroqTalk Local"
if security find-certificate -c "$SIGN_ID" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_ID" \
    --identifier com.groqtalk.app \
    --entitlements GroqTalk/Resources/GroqTalk.entitlements \
    build/GroqTalk.app
  echo "Signed with stable identity: $SIGN_ID"
else
  echo "WARNING: '$SIGN_ID' not in login keychain — falling back to ad-hoc."
  echo "         TCC Accessibility grants will NOT persist across rebuilds."
  echo "         Run scripts/create-signing-cert.sh once to fix this."
  codesign --force --sign - \
    --identifier com.groqtalk.app \
    --entitlements GroqTalk/Resources/GroqTalk.entitlements \
    build/GroqTalk.app
fi

echo "Done! App at: build/GroqTalk.app"
echo "Binary size: $(du -h build/GroqTalk.app/Contents/MacOS/GroqTalk | cut -f1)"
echo ""
echo "Run with: open build/GroqTalk.app"
