#!/usr/bin/env bash
# Downloads the official MobileVLCKit binary (LGPL-2.1) from VideoLAN and verifies the SHA-256
# published in the CocoaPods spec for that version. Output: Vendor/MobileVLCKit.xcframework
# (git-ignored). See docs/adr/0003-playback-engine.md for licensing obligations.
set -euo pipefail
VERSION="3.7.4"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz"
SHA256="c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor"
if [ -d "$DEST/MobileVLCKit.xcframework" ] && [ -f "$DEST/MobileVLCKit.version" ] && [ "$(cat "$DEST/MobileVLCKit.version")" = "$VERSION" ]; then
  echo "MobileVLCKit $VERSION already present"; exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fL --retry 3 -o "$WORK/vlckit.tar.xz" "$URL"
echo "$SHA256  $WORK/vlckit.tar.xz" | shasum -a 256 -c -
mkdir -p "$WORK/x" && tar -xJf "$WORK/vlckit.tar.xz" -C "$WORK/x"
FW="$(find "$WORK/x" -maxdepth 3 -name MobileVLCKit.xcframework -type d | head -1)"
[ -n "$FW" ] || { echo "MobileVLCKit.xcframework not found in archive"; exit 1; }
mkdir -p "$DEST"
rm -rf "$DEST/MobileVLCKit.xcframework"
cp -R "$FW" "$DEST/"
LICENSE="$(find "$WORK/x" -maxdepth 3 -iname 'COPYING*' | head -1)"
[ -n "$LICENSE" ] && cp "$LICENSE" "$DEST/MobileVLCKit-COPYING.txt"
echo "$VERSION" > "$DEST/MobileVLCKit.version"
echo "Installed MobileVLCKit $VERSION into $DEST"
