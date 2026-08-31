#!/usr/bin/env bash
set -euo pipefail

# Publishes a notarized Abaft.app build as a GitHub Release with a signed
# Sparkle appcast.
#
# Usage:
#   scripts/release.sh [--prerelease] <path-to-notarized-Abeam-Receiver.app> [release-notes-file]
#
# --prerelease publishes a release candidate: tagged abaft-v<version>-rc.<n>,
# marked as a GitHub prerelease so it never becomes "latest" and is never
# offered to users via Sparkle. It's a safe way to exercise the whole
# pipeline (notarization check, archiving, appcast generation, upload)
# before cutting the real release. RC runs use a throwaway staging
# directory and never read or write releases/appcast-archives, so they
# can't contaminate the real release history.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_BIN="$REPO_ROOT/.tools/sparkle-bin"

RC_MODE=false
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --prerelease|--rc)
      RC_MODE=true
      ;;
    *)
      POSITIONAL+=("$arg")
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

APP_PATH="${1:?Usage: $0 [--prerelease] <path-to-notarized-.app> [release-notes-file]}"
NOTES_FILE="${2:-}"

if $RC_MODE; then
  ARCHIVE_DIR="$(mktemp -d)/appcast-archives"
else
  ARCHIVE_DIR="releases/appcast-archives"
fi

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
APP_NAME=$(basename "$APP_PATH" .app)
ZIP_NAME="${APP_NAME} ${VERSION}.zip"

if $RC_MODE; then
  RC_NUM=1
  while gh release view "abaft-v${VERSION}-rc.${RC_NUM}" --repo "$REPO" >/dev/null 2>&1; do
    RC_NUM=$((RC_NUM + 1))
  done
  TAG="abaft-v${VERSION}-rc.${RC_NUM}"
  echo "==> Releasing ${APP_NAME} ${VERSION} (build ${BUILD}) as RELEASE CANDIDATE, tag ${TAG}"
  echo "    This will be marked prerelease and will NOT become \"latest\" or reach users via Sparkle."
else
  TAG="abaft-v${VERSION}"
  echo "==> Releasing ${APP_NAME} ${VERSION} (build ${BUILD}) as tag ${TAG}"
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG already exists" >&2
  exit 1
fi

mkdir -p "$ARCHIVE_DIR"

# Pull down the most recent *non-prerelease* releases' zips and appcast.xml
# so generate_appcast can preserve prior entries' URLs and build delta
# patches. Prereleases are excluded from this baseline on every run -
# including RC runs themselves - so a chain of RCs never leaks into the
# real release history or into each other.
echo "==> Syncing recent stable release archives from GitHub"
RECENT_TAGS=$(gh release list --repo "$REPO" --limit 20 --json tagName,isPrerelease,isDraft \
  -q '[.[] | select(.isPrerelease == false and .isDraft == false)] | .[:5] | .[].tagName' 2>/dev/null || true)
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

PRERELEASE_ARGS=()
if $RC_MODE; then
  PRERELEASE_ARGS=(--prerelease --title "$VERSION RC $RC_NUM")
else
  PRERELEASE_ARGS=(--title "$VERSION")
fi

gh release create "$TAG" \
  --repo "$REPO" \
  "${PRERELEASE_ARGS[@]}" \
  "${NOTES_ARGS[@]}" \
  "$ARCHIVE_DIR/$ZIP_NAME" \
  "$ARCHIVE_DIR/appcast.xml"

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
if $RC_MODE; then
  echo "    (prerelease - not visible as \"latest\", not offered via Sparkle)"
fi
