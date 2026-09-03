#!/usr/bin/env bash
set -euox pipefail
shopt -s nullglob

# Builds a signed Sparkle appcast for a notarized Abaft.app build and
# uploads it, alongside the zipped app, to an existing GitHub Release.
#
# This script does NOT create GitHub releases. It only handles the
# Sparkle side (zip, appcast generation, delta patches) and attaches the
# result to a release you already created on GitHub.
#
# Usage:
#   scripts/release.sh [--prerelease] [--notes <file>] <path-to-notarized-Abeam-Receiver.zip>
#
# --notes <file>: attach release notes to this version. <file> must be
# .md, .html, or .txt - generate_appcast embeds it (or links it, for
# non-embedded HTML with a DOCTYPE/body) into the appcast item automatically
# when it shares the archive's base filename, which this script handles by
# copying it in under the right name before generating the appcast.
#
# The argument must be the .zip archive Xcode Cloud produces for the
# notarized build (Xcode Cloud tab in Xcode, or App Store Connect).
# The script expands it to a scratch directory to
# read Info.plist and run the notarization/Gatekeeper checks.
#
# --prerelease targets a release candidate: tag v<version>-rc.<n>,
# where <n> is the highest existing RC number for that version. RCs let you
# exercise the whole pipeline (notarization check, archiving, appcast
# generation, upload) before cutting the real release, without them ever
# becoming "latest" or reaching users via Sparkle. RC runs use a throwaway
# staging directory and never read or write releases/appcast-archives, so
# they can't contaminate the real release history.
#
# One-time prerequisites:
#   - `gh auth login` completed for this machine.
#   - Sparkle EdDSA keypair generated (generate_keys) with the private key in
#     your keychain, and the matching public key in Abaft/Info.plist.
#   - .tools/sparkle-bin/generate_appcast built from the Sparkle SPM checkout.
#
# Per-release workflow:
#   1. Create the GitHub release first: tag v<version> (or
#      v<version>-rc.<n>, marked prerelease, for an RC), via
#      `gh release create` or the GitHub web UI.
#   2. Let Xcode Cloud build, sign (Developer ID), and notarize the app,
#      then download the notarized .zip artifact it produces (Xcode Cloud
#      tab in Xcode, or App Store Connect).
#   3. Run this script with that path. It verifies the notarization ticket,
#      generates the signed Sparkle appcast, and uploads the zip and the
#      appcast as assets onto the release created in step 1.
#
# Versioning note: starting with v1.1.1, Abaft and Abeam share one unified
# version number and an unprefixed tag (v<version>), replacing the old
# abaft-v<version> / abeam-v<version> per-app tag families. Releases tagged
# abaft-v0.0.1 through abaft-v0.0.3 predate the switch and are left as-is.

REPO="onewolfmoon/abeam"
DOWNLOAD_HOST="https://github.com/$REPO/releases/download"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_BIN="$REPO_ROOT/.tools/sparkle-bin"

RC_MODE=false
NOTES_PATH=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prerelease|--rc)
      RC_MODE=true
      shift
      ;;
    --notes)
      NOTES_PATH="${2:?--notes requires a file argument}"
      shift 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

ZIP_PATH="${1:?Usage: $0 [--prerelease] [--notes <file>] <path-to-notarized-.zip>}"

if [[ -n "$NOTES_PATH" ]]; then
  if [[ ! -f "$NOTES_PATH" ]]; then
    echo "error: --notes file $NOTES_PATH not found" >&2
    exit 1
  fi
  case "$NOTES_PATH" in
    *.md|*.html|*.txt) ;;
    *)
      echo "error: --notes file must be .md, .html, or .txt (got $NOTES_PATH)" >&2
      exit 1
      ;;
  esac
fi

if $RC_MODE; then
  ARCHIVE_DIR="$(mktemp -d)/appcast-archives"
else
  ARCHIVE_DIR="releases/appcast-archives"
fi

if [[ "$ZIP_PATH" != *.zip ]]; then
  echo "error: $ZIP_PATH is not a .zip - pass the notarized archive Xcode Cloud produced" >&2
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "error: $ZIP_PATH not found" >&2
  exit 1
fi

ZIP_INPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$ZIP_INPUT_DIR"' EXIT

echo "==> Expanding $ZIP_PATH"
ditto -x -k "$ZIP_PATH" "$ZIP_INPUT_DIR"
EXPANDED_APPS=("$ZIP_INPUT_DIR"/*.app)
if [[ ${#EXPANDED_APPS[@]} -ne 1 ]]; then
  echo "error: expected exactly one .app in $ZIP_PATH, found ${#EXPANDED_APPS[@]}" >&2
  exit 1
fi
APP_PATH="${EXPANDED_APPS[0]}"

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
ZIP_NAME="${APP_NAME// /}-v${VERSION}.zip"

if $RC_MODE; then
  RC_TAGS=$(gh release list --repo "$REPO" --limit 100 --json tagName \
    -q ".[] | select(.tagName | startswith(\"v${VERSION}-rc.\")) | .tagName" 2>/dev/null || true)
  if [[ -z "$RC_TAGS" ]]; then
    echo "error: no RC release found for version $VERSION (v${VERSION}-rc.*)." >&2
    echo "       Create it on GitHub first (as a prerelease), then re-run this script." >&2
    exit 1
  fi
  RC_NUM=$(sed -E 's/.*-rc\.([0-9]+)$/\1/' <<< "$RC_TAGS" | sort -n | tail -n1)
  TAG="v${VERSION}-rc.${RC_NUM}"
  echo "==> Attaching Sparkle assets for ${APP_NAME} ${VERSION} (build ${BUILD}) to RELEASE CANDIDATE tag ${TAG}"
else
  TAG="v${VERSION}"
  echo "==> Attaching Sparkle assets for ${APP_NAME} ${VERSION} (build ${BUILD}) to tag ${TAG}"
fi

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: release $TAG not found on GitHub." >&2
  echo "       Create it first (gh release create or the web UI), then re-run this script." >&2
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
cp "$ZIP_PATH" "$ARCHIVE_DIR/$ZIP_NAME"

if [[ -n "$NOTES_PATH" ]]; then
  NOTES_EXT="${NOTES_PATH##*.}"
  NOTES_NAME="${ZIP_NAME%.zip}.${NOTES_EXT}"
  echo "==> Attaching release notes ($NOTES_NAME)"
  cp "$NOTES_PATH" "$ARCHIVE_DIR/$NOTES_NAME"
fi

echo "==> Generating appcast"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_HOST/$TAG/" \
  "$ARCHIVE_DIR"

# Upload everything generate_appcast left in the archive root: the current
# zip, every older zip still within its --maximum-versions window (their
# enclosure URLs get rewritten to this tag too), and any delta patches it
# generated (--maximum-deltas). Files it pruned into old_updates/ are
# intentionally left behind - nullglob means *.delta expands to nothing
# when no deltas were generated (e.g. across an app-bundle rename).
UPLOAD_FILES=("$ARCHIVE_DIR"/*.zip "$ARCHIVE_DIR"/*.delta "$ARCHIVE_DIR"/*.md "$ARCHIVE_DIR"/*.html "$ARCHIVE_DIR"/*.txt "$ARCHIVE_DIR/appcast.xml")

echo "==> Uploading Sparkle assets to GitHub release $TAG"
printf '    %s\n' "${UPLOAD_FILES[@]##*/}"
gh release upload "$TAG" \
  --repo "$REPO" \
  --clobber \
  "${UPLOAD_FILES[@]}"

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
if $RC_MODE; then
  echo "    (prerelease - not visible as \"latest\", not offered via Sparkle)"
fi
