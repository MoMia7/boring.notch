#!/bin/zsh
# Build a signed Notch Agent.dmg for a GitHub release.
#   scripts/release.sh            # signs with the first "Apple Development" identity (or ad-hoc)
#   SIGN_IDENTITY=- scripts/release.sh
set -euo pipefail
REPO="${0:A:h:h}"
OUT="$REPO/build/release"
DERIVED="$REPO/build/DerivedData"
TMP=$(mktemp -d)
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"

rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project "$REPO/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual build -quiet

APP="$OUT/Notch Agent.app"
ditto "$DERIVED/Build/Products/Release/Notch Agent.app" "$APP"

# Prebuilt frameworks carry upstream's Team ID; re-sign all nested code with one identity.
sign() {
  local target="$1" ents="$TMP/$RANDOM.plist"
  local -a args=(--force --sign "$IDENTITY" --options runtime --timestamp=none)
  if codesign -d --entitlements :- "$target" > "$ents" 2>/dev/null && [[ -s "$ents" ]]; then
    args+=(--entitlements "$ents")
  fi
  codesign "${args[@]}" "$target"
}
find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) -print0 |
  while IFS= read -r -d '' item; do sign "$item"; done
codesign -d --entitlements :- "$DERIVED/Build/Products/Release/Notch Agent.app" > "$TMP/app.plist" 2>/dev/null
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements "$TMP/app.plist" "$APP"
codesign --verify --deep --strict "$APP"

# Drag-to-Applications disk image.
STAGE="$TMP/dmg" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Notch Agent.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Notch Agent" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Notch-Agent.dmg" >/dev/null
shasum -a 256 "$OUT/Notch-Agent.dmg"

# Sparkle: sign the DMG (EdDSA key in the login keychain, account "notch-agent") and add
# it to appcast.xml, which installed copies check daily. Commit appcast.xml after the
# GitHub release is published.
SIGN_UPDATE=$(find "$DERIVED/SourcePackages/artifacts" -path '*Sparkle/bin/sign_update' -not -path '*old_dsa*' | head -1)
INFO="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$INFO")
SIGNATURE=$("$SIGN_UPDATE" --account notch-agent "$OUT/Notch-Agent.dmg")
python3 - "$REPO/appcast.xml" "$VERSION" "$BUILD" "$SIGNATURE" <<'PY'
import sys, re, email.utils
path, version, build, signature = sys.argv[1:5]
url = f"https://github.com/MoMia7/boring.notch/releases/download/v{version}/Notch-Agent.dmg"
item = f"""    <item>
      <title>Notch Agent {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/MoMia7/boring.notch/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{url}" {signature} type="application/octet-stream"/>
    </item>
"""
xml = open(path).read()
xml = re.sub(r"    <item>\s*<title>Notch Agent " + re.escape(version) + r"</title>.*?</item>\n", "", xml, flags=re.S)
xml = xml.replace("    <title>Notch Agent</title>\n", "    <title>Notch Agent</title>\n" + item, 1)
open(path, "w").write(xml)
PY
echo "Built $OUT/Notch-Agent.dmg (v$VERSION build $BUILD); appcast.xml updated"
