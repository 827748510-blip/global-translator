#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
binary_dir="$(swift build -c release --show-bin-path)"
bundle="$project_dir/.build/desktop/Global Translator.app"
# Only disposable build artifacts are replaced here; installation is separate.
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 0755 "$binary_dir/global-translator" "$bundle/Contents/MacOS/global-translator"
cp packaging/Info.plist "$bundle/Contents/Info.plist"
swift scripts/make-app-icon.swift "$bundle/Contents/Resources/AppIcon.icns"
# Persistent self-signed identity ("Global Translator Dev" in the login
# keychain). Ad-hoc signing (-) changes cdhash on every rebuild, which makes
# macOS TCC drop Accessibility/ScreenCapture grants after each update.
codesign --force --sign "Global Translator Dev" "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
