#!/usr/bin/env bash
set -euo pipefail

# Publishes a notarized Abaft.app build as a GitHub Release with a signed
# Sparkle appcast.
#
# Usage:
#   scripts/release.sh <path-to-notarized-Abeam-Receiver.app> [release-notes-file]
#
# One-time prerequisites:
#   - A "Developer ID Application" certificate in your keychain.
#   - `gh auth login` completed for this machine.
#   - Sparkle EdDSA keypair generated (generate_keys) with the private key in
#     your keychain, and the matching public key in Abaft/Info.plist.
#   - .tools/sparkle-bin/generate_appcast built from the Sparkle SPM checkout.
#
# Per-release workflow:
#   1. In Xcode: Product > Archive, then Organizer > Distribute App >
#      Direct Distribution. This signs with your Developer ID cert,
#      notarizes, and staples the ticket. Note the exported .app path.
#   2. Run this script with that path.

REPO="onewolfmoon/abeam"
DOWNLOAD_HOST="https://github.com/$REPO/releases/download"
ARCHIVE_DIR="releases/appcast-archives"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_BIN="$REPO_ROOT/.tools/sparkle-bin"

APP_PATH="${1:?Usage: $0 <path-to-notarized-.app> [release-notes-file]}"
NOTES_FILE="${2:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH not found" >&2
  exit 1
fi

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "error: $SPARKLE_BIN/generate_appcast not found or not executable" >&2
  exit 1
fi

echo "==> Verifying notarization ticket is stapled"
xcrun stapler validate "$APP_PATH"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
TAG="abaft-v${VERSION}"
APP_NAME=$(basename "$APP_PATH" .app)
ZIP_NAME="${APP_NAME} ${VERSION}.zip"

echo "==> Releasing ${APP_NAME} ${VERSION} (build ${BUILD}) as tag ${TAG}"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists" >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR"

# Pull down the most recent releases' zips and the current appcast.xml so
# generate_appcast can preserve prior entries' URLs and build delta patches,
# even if this machine's local archive folder was wiped or is fresh.
echo "==> Syncing recent release archives from GitHub"
RECENT_TAGS=$(gh release list --repo "$REPO" --limit 5 --json tagName -q '.[].tagName' 2>/dev/null || true)
if [[ -n "$RECENT_TAGS" ]]; then
  while IFS= read -r prior_tag; do
    [[ -z "$prior_tag" ]] && continue
    gh release download "$prior_tag" --repo "$REPO" \
      --pattern "*.zip" --dir "$ARCHIVE_DIR" --clobber 2>/dev/null || true
  done <<< "$RECENT_TAGS"

  LATEST_TAG=$(head -n1 <<< "$RECENT_TAGS")
  gh release download "$LATEST_TAG" --repo "$REPO" \
    --pattern "appcast.xml" --dir "$ARCHIVE_DIR" --clobber 2>/dev/null || true
fi

echo "==> Archiving build"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_DIR/$ZIP_NAME"

echo "==> Generating appcast"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_HOST/$TAG/" \
  "$ARCHIVE_DIR"

echo "==> Publishing GitHub release $TAG"
NOTES_ARGS=(--notes "Abeam Receiver $VERSION")
if [[ -n "$NOTES_FILE" ]]; then
  NOTES_ARGS=(--notes-file "$NOTES_FILE")
fi

gh release create "$TAG" \
  --repo "$REPO" \
  --title "$VERSION" \
  "${NOTES_ARGS[@]}" \
  "$ARCHIVE_DIR/$ZIP_NAME" \
  "$ARCHIVE_DIR/appcast.xml"

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
