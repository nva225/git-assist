#!/bin/bash
# Builds build/GitAssist.app with swiftc (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/GitAssist.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/GitAssist" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.nickva.gitassist "$APP"

echo "Built $APP"
