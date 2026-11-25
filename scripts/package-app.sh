#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift_flags=(-c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
if [[ -n "${SWIFTPM_EXTRA_FLAGS:-}" ]]; then
    read -r -a extra_flags <<< "${SWIFTPM_EXTRA_FLAGS}"
    swift_flags+=("${extra_flags[@]}")
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
# Sign with Hardened Runtime (--options runtime). Ad-hoc ("-") stays supported
# for local builds, while Developer ID / local dev certs gain timestamping and
# optional entitlements.
codesign_identity="${CODESIGN_IDENTITY:--}"
codesign_args=(--force --options runtime --sign "$codesign_identity")
if [[ "$codesign_identity" != "-" ]]; then
    codesign_args+=(--timestamp)
fi
if [[ -n "${CODESIGN_ENTITLEMENTS:-}" ]]; then
    codesign_args+=(--entitlements "$CODESIGN_ENTITLEMENTS")
fi
codesign "${codesign_args[@]}" "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
