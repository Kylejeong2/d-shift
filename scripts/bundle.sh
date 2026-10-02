#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) D-Shift.app and a zip for distribution.
#
#   ./scripts/bundle.sh [version]        version defaults to the latest git tag, without the leading "v"
#
# Signing: set CODESIGN_IDENTITY to a "Developer ID Application: ..." identity to sign for distribution.
# Without it the app is ad-hoc signed, which runs fine locally but makes Gatekeeper warn on other Macs.
# Notarization (optional): also set NOTARY_PROFILE to a profile created with `xcrun notarytool store-credentials`.
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
dist="dist"
app="$dist/D-Shift.app"

echo "Building D-Shift $version"
rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Build each architecture separately and merge, which works with the Command Line Tools alone.
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" --product DShift
done
lipo -create -output "$app/Contents/MacOS/DShift" \
  ".build/arm64-apple-macosx/release/DShift" \
  ".build/x86_64-apple-macosx/release/DShift"

sed "s/__VERSION__/$version/g" Packaging/Info.plist > "$app/Contents/Info.plist"

iconset="$dist/AppIcon.iconset"
swift scripts/make-icon.swift "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

identity="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
codesign --verify --strict "$app"

zip="$dist/D-Shift-$version.zip"
ditto -c -k --keepParent "$app" "$zip"

if [[ -n "${NOTARY_PROFILE:-}" && "$identity" != "-" ]]; then
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm "$zip" && ditto -c -k --keepParent "$app" "$zip"
fi

echo "Built $app and $zip"
