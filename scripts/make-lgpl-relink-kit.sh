#!/usr/bin/env bash
# LGPL-2.1 §6 relink kit for one Seyrileo release (keep it for at least three years; hand it out on
# request together with the VLCKit source). It contains Seyrileo's own object files (app, SeyrileoKit,
# GRDB), the exact linker command Xcode used, and instructions to relink against a modified
# MobileVLCKit. It never contains credentials, Vendor/ binaries or the app's Swift sources.
#
# Usage: scripts/make-lgpl-relink-kit.sh            (builds Release for generic iOS, then packs)
# Output: build/lgpl-relink-kit-<version>-<build>.zip
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/RelinkKitDerivedData"
LOG="$(mktemp)"
rm -rf "$DD"
xcodebuild -project "$ROOT/Seyrileo.xcodeproj" -scheme Seyrileo -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -allowProvisioningUpdates build > "$LOG"
APP="$DD/Build/Products/Release-iphoneos/Seyrileo.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Info.plist")
KIT="$(mktemp -d)/lgpl-relink-kit-$VERSION-$BUILD"
OBJ_REL="Build/Intermediates.noindex/Seyrileo.build/Release-iphoneos/Seyrileo.build/Objects-normal/arm64"
PROD_REL="Build/Products/Release-iphoneos"
mkdir -p "$KIT/derived-data/$OBJ_REL" "$KIT/derived-data/$PROD_REL" "$KIT/derived-data/Build/Intermediates.noindex/EagerLinkingTBDs/Release-iphoneos"
# The app's object files and the package objects (SeyrileoKit, SeyrileoFixtureServer, GRDB).
cp "$DD/$OBJ_REL/"*.o "$KIT/derived-data/$OBJ_REL/"
cp "$DD/$PROD_REL/"*.o "$KIT/derived-data/$PROD_REL/"
cp -R "$DD/$PROD_REL/PackageFrameworks" "$DD/$PROD_REL/MobileVLCKit.framework" "$KIT/derived-data/$PROD_REL/"
# File list and linker command with the build machine's paths replaced by placeholders.
sed "s#$DD#\$DERIVED_DATA#g" "$DD/$OBJ_REL/Seyrileo.LinkFileList" > "$KIT/Seyrileo.LinkFileList.template"
awk '/^Ld .*Seyrileo\.app\/Seyrileo normal/{found=1; next} found && /clang/{print; exit}' "$LOG" \
  | sed "s#$DD#\$DERIVED_DATA#g; s#$ROOT#\$PROJECT#g" > "$KIT/link-command.txt"
test -s "$KIT/link-command.txt"
cat > "$KIT/relink.sh" <<'RELINK'
#!/usr/bin/env bash
# Relinks the Seyrileo binary. Replace derived-data/Build/Products/Release-iphoneos/MobileVLCKit.framework
# with your modified build first. Output: ./Seyrileo (put it into a copy of Seyrileo.app and sign it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$HERE/derived-data"
sed "s#\$DERIVED_DATA#$DERIVED_DATA#g" "$HERE/Seyrileo.LinkFileList.template" > "$HERE/Seyrileo.LinkFileList"
COMMAND=$(sed "s#\$DERIVED_DATA#$DERIVED_DATA#g; s#\$PROJECT#$HERE#g" "$HERE/link-command.txt" \
  | sed -E "s#-filelist [^ ]+#-filelist $HERE/Seyrileo.LinkFileList#; s#-o [^ ]+Seyrileo\.app/Seyrileo#-o $HERE/Seyrileo#" \
  | sed -E "s#-Xlinker -dependency_info -Xlinker [^ ]+##; s#-Xlinker -object_path_lto -Xlinker [^ ]+##")
eval "$COMMAND"
echo "$HERE/Seyrileo"
RELINK
chmod +x "$KIT/relink.sh"

cat > "$KIT/README.txt" <<EOF
Seyrileo $VERSION ($BUILD) — LGPL-2.1 relink kit for MobileVLCKit

Seyrileo dynamically links MobileVLCKit 3.7.4 (LGPL-2.1 or later), unmodified, from the official
VideoLAN binary. Source: https://code.videolan.org/videolan/VLCKit (tag 3.7.4); a copy is available
from us on request.

To use a modified MobileVLCKit:
1. Build your MobileVLCKit.framework (iOS arm64, same public API as 3.7.4).
2. Replace derived-data/Build/Products/Release-iphoneos/MobileVLCKit.framework with yours and run
   ./relink.sh on a Mac with the Xcode version below. It links the object files in derived-data/
   with the original linker command (link-command.txt) and writes ./Seyrileo.
3. Put the new binary into a copy of Seyrileo.app, replace Frameworks/MobileVLCKit.framework with
   yours, and sign with your own Apple development identity to run it on your device.

Built with: $(xcodebuild -version | tr '\n' ' ')
EOF
rm -f "$ROOT/build/$(basename "$KIT").zip"
rm -f "$ROOT/build/$(basename "$KIT").zip"
(cd "$(dirname "$KIT")" && zip -qr "$ROOT/build/$(basename "$KIT").zip" "$(basename "$KIT")")
rm -f "$LOG"
echo "$ROOT/build/$(basename "$KIT").zip"
