#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift_flags=(-c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
if [[ -n "${SWIFTPM_EXTRA_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    swift_flags+=(${SWIFTPM_EXTRA_FLAGS})
fi
swift build "${swift_flags[@]}"
binary_dir="$(swift build "${swift_flags[@]}" --show-bin-path)"
bundle="$project_dir/.build/desktop/Global Translator.app"
# Only disposable build artifacts are replaced here; installation is separate.
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -m 0755 "$binary_dir/global-translator" "$bundle/Contents/MacOS/global-translator"
cp packaging/Info.plist "$bundle/Contents/Info.plist"
swift scripts/make-app-icon.swift "$bundle/Contents/Resources/AppIcon.icns"
# Default to ad-hoc signing ("-") so fresh clones build out of the box without a
# local keychain certificate. Set CODESIGN_IDENTITY (e.g. "Global Translator Dev"
# or a Developer ID) to keep a stable cdhash across rebuilds for macOS TCC grants.
codesign_identity="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$codesign_identity" "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
