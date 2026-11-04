#!/bin/bash
# Build the SwiftPM executable, assemble build/AudioControl.app, and sign it.
# Never sign by name: codesign matches common names by substring, so resolve
# the exact-name identity to its SHA-1 first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AudioControl"
BUNDLE_ID="${BUNDLE_ID:-com.pedroaraujo.audiocontrol}"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-AudioControl Dev}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/__APP_NAME__/$APP_NAME/g" \
    "$ROOT/Resources/Info.plist.template" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- App icon -----------------------------------------------------------------
# Resources/AppIcon.icon is an Icon Composer bundle (icon.json + SVG layers),
# hand-written. Only Xcode's actool compiles it (Command Line Tools lack it), so
# point DEVELOPER_DIR at Xcode for this one call; the Swift build above keeps
# using whatever xcode-select says. actool emits Assets.car (macOS 26+ layered
# icon) and AppIcon.icns (fallback for macOS 15). Without Xcode, skip the icon.
XCODE_DEV="${XCODE_DEV:-}"
if [[ -z "$XCODE_DEV" ]]; then
  XCODE_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1 || true)"
  [[ -z "$XCODE_APP" && -d /Applications/Xcode.app ]] && XCODE_APP=/Applications/Xcode.app
  [[ -n "$XCODE_APP" ]] && XCODE_DEV="$XCODE_APP/Contents/Developer"
fi
if [[ -n "$XCODE_DEV" ]] && DEVELOPER_DIR="$XCODE_DEV" xcrun --find actool >/dev/null 2>&1; then
  echo "==> actool AppIcon.icon"
  ICON_TMP="$(mktemp -d)"
  DEVELOPER_DIR="$XCODE_DEV" xcrun actool "$ROOT/Resources/AppIcon.icon" \
    --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 15.0 \
    --output-partial-info-plist "$ICON_TMP/partial.plist" \
    --output-format human-readable-text --errors --warnings >"$ICON_TMP/actool.log" 2>&1 \
    || { cat "$ICON_TMP/actool.log" >&2; exit 1; }
  grep -iE 'error|warning' "$ICON_TMP/actool.log" | sed 's/^/    /' || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
  rm -rf "$ICON_TMP"
else
  echo "WARNING: Xcode not found; building without an app icon (actool ships only with Xcode)." >&2
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Optional helper bundle (probe fallback A2), only if the target exists.
if [[ -x "$BIN_DIR/AudioControlTone" ]]; then
  TONE="$APP/Contents/Resources/AudioControlTone.app"
  mkdir -p "$TONE/Contents/MacOS"
  cp "$BIN_DIR/AudioControlTone" "$TONE/Contents/MacOS/AudioControlTone"
  sed -e "s/__BUNDLE_ID__/$BUNDLE_ID.tone/g" -e "s/__VERSION__/$VERSION/g" \
      -e "s/__BUILD__/$BUILD_NUMBER/g" -e "s/__APP_NAME__/AudioControlTone/g" \
      "$ROOT/Resources/Info.plist.template" > "$TONE/Contents/Info.plist"
fi

# --- Fix the SDK stamp ------------------------------------------------------
# SwiftPM 6.4 with Command Line Tools compiles against the current SDK but
# records the deployment target as the SDK version in LC_BUILD_VERSION.
# AppKit reads that stamp to decide the app's design generation, so a
# "sdk 15.0" stamp gets the pre-macOS 26 compatibility look. Rewrite it to
# the real SDK version, keeping the minimum OS, before signing.
SDK_VERSION="$(xcrun --show-sdk-version)"
fix_sdk_stamp() {
  local bin="$1" minos sdk
  minos="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  sdk="$(otool -l "$bin" | awk '/LC_BUILD_VERSION/{f=1} f&&/ sdk /{print $2; exit}')"
  if [[ "$sdk" != "$SDK_VERSION" ]]; then
    xcrun vtool -set-build-version macos "$minos" "$SDK_VERSION" -replace -output "$bin.tmp" "$bin"
    mv "$bin.tmp" "$bin"
    chmod +x "$bin"
    echo "    SDK stamp $(basename "$bin"): $sdk -> $SDK_VERSION (minos $minos)"
  fi
}
fix_sdk_stamp "$APP/Contents/MacOS/$APP_NAME"
if [[ -x "$APP/Contents/Resources/AudioControlTone.app/Contents/MacOS/AudioControlTone" ]]; then
  fix_sdk_stamp "$APP/Contents/Resources/AudioControlTone.app/Contents/MacOS/AudioControlTone"
fi

# --- Resolve signing identity to a hash ------------------------------------
SIGN_WITH="-"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  # Lines look like:   1) <SHA1> "AudioControl Dev"
  MATCHES="$(security find-identity -v -p codesigning 2>/dev/null \
             | grep -F "\"$SIGN_IDENTITY\"" | awk '{print $2}' || true)"
  COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
  if (( COUNT > 1 )); then
    echo "error: more than one valid identity named exactly '$SIGN_IDENTITY':" >&2
    echo "$MATCHES" >&2
    exit 1
  elif (( COUNT == 1 )); then
    SIGN_WITH="$MATCHES"
  else
    echo "WARNING: no valid identity named '$SIGN_IDENTITY'. Falling back to AD-HOC signing." >&2
    echo "         TCC will re-prompt after every rebuild. Run scripts/make-signing-cert.sh." >&2
  fi
fi

echo "==> codesign ($([[ "$SIGN_WITH" == "-" ]] && echo ad-hoc || echo "$SIGN_IDENTITY $SIGN_WITH"))"
if [[ -d "$APP/Contents/Resources/AudioControlTone.app" ]]; then
  codesign --force --sign "$SIGN_WITH" --identifier "$BUNDLE_ID.tone" \
    "$APP/Contents/Resources/AudioControlTone.app"
fi
codesign --force --sign "$SIGN_WITH" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

if [[ "$SIGN_WITH" != "-" ]]; then
  EXP="$(security find-certificate -a -p -c "$SIGN_IDENTITY" 2>/dev/null \
         | /usr/bin/openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//' || true)"
  [[ -n "$EXP" ]] && echo "    certificate expires: $EXP"
fi
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Signature|Authority)' | sed 's/^/    /'
echo "==> built $APP"
