#!/usr/bin/env bash
# Builds a Release .app and packages it into a distributable .dmg.
# Signs with a stable identity (not notarized). A stable identity matters:
# macOS ties the Accessibility grant to the code signature, and an ad-hoc
# signature changes with every build, so each update would lose the grant.
#
# Identity: $SIGN_IDENTITY if set, otherwise the first "Developer ID
# Application" or "Apple Development" certificate in the keychain, otherwise
# ad-hoc (with a warning).
#
# Usage:
#   scripts/build-dmg.sh
#
# Requires:
#   - Full Xcode (not just Command Line Tools).
#   - Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DMG_DIR="$BUILD_DIR/dmg-staging"
APP_NAME="Blablabla"
SCHEME="$APP_NAME"
PROJECT_FILE="$PROJECT_DIR/$APP_NAME.xcodeproj"
DMG_NAME="$APP_NAME.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# Pick up the version from MARKETING_VERSION in pbxproj.
VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT_FILE/project.pbxproj" | sed 's/[^0-9.]//g' | head -c 16)
[ -z "$VERSION" ] && VERSION="1.0"

echo "==> Building $APP_NAME v$VERSION (Release)"
# Keep DerivedData between runs: a clean MLX build takes 10+ minutes.
rm -rf "$DMG_DIR" "$DMG_PATH" "$BUILD_DIR/build.log"
mkdir -p "$BUILD_DIR"

# Locate full Xcode. xcode-select may point at Command Line Tools, but if
# /Applications/Xcode.app exists we can pin DEVELOPER_DIR ourselves and avoid
# requiring sudo xcode-select.
if ! xcodebuild -version > /dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        echo "==> Using Xcode at $DEVELOPER_DIR"
    else
        echo "ERROR: full Xcode is required at /Applications/Xcode.app." >&2
        echo "       Install Xcode from the App Store, or run:" >&2
        echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        exit 1
    fi
fi

xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination "generic/platform=macOS" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    VALID_ARCHS=arm64 \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    build 2>&1 | tee "$BUILD_DIR/build.log" | grep -E "(error:|warning:|FAILED|Compiling|Linking)" || true

# Bail if the .app didn't get produced.
APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ] || [ ! -f "$APP_PATH/Contents/MacOS/$APP_NAME" ]; then
    echo "" >&2
    echo "ERROR: build failed. Last error lines:" >&2
    grep -B 2 "error:" "$BUILD_DIR/build.log" | tail -40 >&2
    exit 1
fi

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    for kind in "Developer ID Application" "Apple Development"; do
        IDENTITY=$(security find-identity -v -p codesigning | grep "\"$kind" | head -1 | sed -E 's/.*"(.*)".*/\1/') || true
        [ -n "$IDENTITY" ] && break
    done
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing app with \"$IDENTITY\""
    codesign --force --deep --sign "$IDENTITY" "$APP_PATH"
else
    echo "WARNING: no signing certificate found — signing ad-hoc." >&2
    echo "         Accessibility permission will reset on every update." >&2
    codesign --force --deep --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
echo "    Designated requirement: $(codesign -dr - "$APP_PATH" 2>&1 | grep designated)"

echo "==> Staging DMG contents"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

echo "==> Creating compressed DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

# Cleanup staging now that DMG is sealed.
rm -rf "$DMG_DIR"

SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "==> Done. DMG: $DMG_PATH ($SIZE)"
echo ""
echo "    Open:    open \"$DMG_PATH\""
echo "    Install: drag $APP_NAME.app onto Applications inside the mounted DMG."
echo ""
echo "    First launch:"
echo "      Right-click $APP_NAME.app → Open → Open (not notarized — Gatekeeper warns once)."
