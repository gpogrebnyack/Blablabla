#!/usr/bin/env bash
# Cuts a release that existing installs pick up over the air via Sparkle.
#
# Usage:
#   scripts/release.sh <version> [notes.md] [--dry-run]
#
#   <version>   marketing version, e.g. 1.3
#   notes.md    release notes, one "- item" per line (shown in the update
#               window and on the GitHub release). Defaults to a stub.
#   --dry-run   build, sign and write the appcast, but don't publish.
#
# Steps: bump MARKETING_VERSION + CURRENT_PROJECT_VERSION → build-dmg.sh →
# pull the current appcast from the latest GitHub release → generate_appcast
# (EdDSA-signs the DMG with the key in your login keychain) → commit + push the
# bump → gh release create with the DMG and the new appcast.xml attached.
#
# Sparkle reads the feed from .../releases/latest/download/appcast.xml, so the
# appcast must ride along with every release — the newest one is the feed.

set -euo pipefail

REPO="gpogrebnyack/Blablabla"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$PROJECT_DIR/Blablabla.xcodeproj/project.pbxproj"
BUILD_DIR="$PROJECT_DIR/build"
UPDATES_DIR="$BUILD_DIR/updates"
SPARKLE_BIN="$BUILD_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

VERSION=""
NOTES=""
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) if [ -z "$VERSION" ]; then VERSION="$arg"; else NOTES="$arg"; fi ;;
    esac
done

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "Usage: scripts/release.sh <version> [notes.md] [--dry-run]" >&2
    exit 1
fi
TAG="v$VERSION"

if [ "$DRY_RUN" -eq 0 ]; then
    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]; then
        echo "ERROR: commit your changes first — the release tag points at HEAD." >&2
        exit 1
    fi
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "ERROR: release $TAG already exists." >&2
        exit 1
    fi
fi

# Sparkle compares CFBundleVersion, so it must grow on every release.
BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" | sed 's/[^0-9]//g')
BUILD=$((BUILD + 1))
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PBXPROJ"
echo "==> Releasing $VERSION (build $BUILD)"

bash "$PROJECT_DIR/scripts/build-dmg.sh"

if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "ERROR: Sparkle tools not found at $SPARKLE_BIN (resolve packages first)." >&2
    exit 1
fi

# Only the new archive goes in the folder; older entries stay in the appcast
# with their original download URLs.
rm -rf "$UPDATES_DIR"
mkdir -p "$UPDATES_DIR"
ARCHIVE="$UPDATES_DIR/Blablabla-$VERSION.dmg"
cp "$BUILD_DIR/Blablabla.dmg" "$ARCHIVE"

if gh release download -R "$REPO" --pattern appcast.xml --dir "$UPDATES_DIR" >/dev/null 2>&1; then
    echo "==> Extending the existing appcast"
else
    echo "==> No appcast in the latest release — starting a new one"
fi

# Release notes: Markdown bullets → the HTML Sparkle shows in its update window.
NOTES_MD="$UPDATES_DIR/notes.md"
if [ -n "$NOTES" ]; then cp "$NOTES" "$NOTES_MD"; else echo "- Bug fixes and improvements." > "$NOTES_MD"; fi
{
    echo "<ul>"
    sed -nE 's/^[-*] +(.*)$/  <li>\1<\/li>/p' "$NOTES_MD"
    echo "</ul>"
} > "$UPDATES_DIR/Blablabla-$VERSION.html"

"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    --maximum-deltas 0 \
    --link "https://github.com/$REPO" \
    "$UPDATES_DIR"

grep -q "sparkle:edSignature" "$UPDATES_DIR/appcast.xml" || {
    echo "ERROR: appcast has no EdDSA signature — is the Sparkle key in your keychain?" >&2
    exit 1
}

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "==> Dry run done. Nothing published."
    echo "    Archive: $ARCHIVE"
    echo "    Appcast: $UPDATES_DIR/appcast.xml"
    echo "    Version bump left in project.pbxproj."
    exit 0
fi

echo "==> Committing version bump and pushing"
git -C "$PROJECT_DIR" commit -q -m "Release $VERSION" -- "$PBXPROJ"
git -C "$PROJECT_DIR" push -q

echo "==> Publishing $TAG"
gh release create "$TAG" \
    -R "$REPO" \
    --target "$(git -C "$PROJECT_DIR" rev-parse HEAD)" \
    --title "$TAG" \
    --notes-file "$NOTES_MD" \
    "$ARCHIVE" \
    "$UPDATES_DIR/appcast.xml"

echo ""
echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
