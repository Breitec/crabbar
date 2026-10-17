#!/bin/zsh
# Renders the app icons from Clawd's sprite data: docs/icon.png, all macOS sizes, and the full-bleed iOS icon.
set -euo pipefail
root=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{ print "import Foundation\nimport CoreGraphics"
  grep -v '^import ' "$root/Packages/ClawdCore/Sources/ClawdCore/ClawdSprite.swift"
  cat "$root/tools/make-icon.swift"; } > "$tmp/all.swift"
swiftc -O -o "$tmp/draw" "$tmp/all.swift"
"$tmp/draw" "$root/docs/icon.png"
set="$root/CrabBar/Assets.xcassets/AppIcon.appiconset"
for sz in 16 32 64 128 256 512 1024; do
  sips -z $sz $sz "$root/docs/icon.png" --out "$set/icon_$sz.png" >/dev/null
done
ios="$root/CrabBariOS/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ios"
"$tmp/draw" "$ios/icon-ios-1024.png" --full-bleed
echo "icon updated"
