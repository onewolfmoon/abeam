#!/usr/bin/env bash
set -euox pipefail
shopt -s nullglob

# Builds a signed Sparkle appcast for a notarized Abaft.app build and
# publishes it, alongside the zipped app and delta patches, to the
# project's GitHub Pages checkout (../abeam-pages, updates/). The current
# version's zip and a copy of appcast.xml are also attached to the GitHub
# Release you already created, but old versions' zips/deltas are NOT
# re-uploaded there on every run - that redundant re-upload of files
# unrelated to the current release is exactly what this setup replaces.
# See the "Sparkle hosting" note near the bottom of this header.
#
# This script does NOT create GitHub releases. It only handles the
# Sparkle side (zip, appcast generation, delta patches) and publishes the
# result to ../abeam-pages, plus a couple of bridge files onto a release
# you already created on GitHub.
#
# Usage:
#   scripts/release.sh [--prerelease] [--notes <file>] <path-to-notarized.zip-or-.app>
#
# --notes <file>: attach release notes to this version. <file> must be
# .md, .html, or .txt - generate_appcast embeds it (or links it, for
# non-embedded HTML with a DOCTYPE/body) into the appcast item automatically
# when it shares the archive's base filename, which this script handles by
# copying it in under the right name before generating the appcast.
#
# The argument is either the .zip archive Xcode Cloud produces for the
# notarized build (Xcode Cloud tab in Xcode, or App Store Connect), or the
# notarized .app extracted from it (e.g. after manually renaming the bundle
# to work around Xcode Cloud producing the wrong product name). A .zip is
# expanded to a scratch directory to read Info.plist and run the
# notarization/Gatekeeper checks; a .app is zipped (ditto, preserving
# resource forks) into the archive from that same scratch directory.
#
# --prerelease targets a release candidate: tag v<version>-rc.<n>,
# where <n> is the highest existing RC number for that version. RCs let you
# exercise the whole pipeline (notarization check, archiving, appcast
# generation, upload) before cutting the real release, without them ever
# becoming "latest" or reaching users via Sparkle. RC runs use a throwaway
# staging directory and never read or write ../abeam-pages, so they can't
# contaminate the real release history.
#
# One-time prerequisites:
#   - `gh auth login` completed for this machine.
#   - Sparkle EdDSA keypair generated (generate_keys) with the private key in
#     your keychain, and the matching public key in Abaft/Info.plist.
#   - .tools/sparkle-bin/generate_appcast built from the Sparkle SPM checkout.
#   - ../abeam-pages checked out next to this repo (jj, tracking gh-pages).
#     Keep it up to date before releasing: `jj git fetch && jj new gh-pages@origin`
#     in that directory if you're not sure it's current.
#
# Per-release workflow:
#   1. Create the GitHub release first: tag v<version> (or
#      v<version>-rc.<n>, marked prerelease, for an RC), via
#      `gh release create` or the GitHub web UI.
#   2. Let Xcode Cloud build, sign (Developer ID), and notarize the app,
#      then download the notarized .zip artifact it produces (Xcode Cloud
#      tab in Xcode, or App Store Connect).
#   3. Run this script with that path. It verifies the notarization ticket,
#      generates the signed Sparkle appcast into ../abeam-pages/updates,
#      pushes that branch, and attaches the current zip (+ appcast.xml, as
#      a bridge - see below) onto the release created in step 1.
#
# Versioning note: starting with v1.1.1, Abaft and Abeam share one unified
# version number and an unprefixed tag (v<version>), replacing the old
# abaft-v<version> / abeam-v<version> per-app tag families. Releases tagged
# abaft-v0.0.1 through abaft-v0.0.3 predate the switch and are left as-is.
#
# Sparkle hosting note: full update archives, delta patches, and appcast.xml
# live in ../abeam-pages/updates (the project's GitHub Pages checkout), not
# on GitHub Releases. generate_appcast wants one stable directory it can
# maintain a rolling delta window in and that gets synced wholesale on every
# run; GitHub Releases' per-tag asset lists don't offer that; each run would
# otherwise have to re-upload every zip/delta still inside the window to
# whichever tag is newest, since generate_appcast rewrites every item's
# enclosure URL to match --download-url-prefix on every run. SUFeedURL
# points at the Pages URL now. The current version's zip and appcast.xml are
# still uploaded onto the GitHub release as a bridge - installed apps whose
# SUFeedURL still points at the old
# releases/latest/download/appcast.xml location keep getting a valid,
# current appcast (pointing at Pages-hosted downloads) until they update to
# a build with the new SUFeedURL baked in.

REPO="onewolfmoon/abeam"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPARKLE_BIN="$REPO_ROOT/.tools/sparkle-bin"
if [[ ! -d "$REPO_ROOT/../abeam-pages" ]]; then
  echo "error: $REPO_ROOT/../abeam-pages not found - check out the gh-pages checkout there first" >&2
  exit 1
fi
PAGES_DIR="$(cd "$REPO_ROOT/../abeam-pages" && pwd)"
PAGES_UPDATES_DIR="$PAGES_DIR/updates"
PAGES_BASE_URL="https://abeam.wolfmoon.dev/updates"

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

INPUT_PATH="${1:?Usage: $0 [--prerelease] [--notes <file>] <path-to-notarized-.zip-or-.app>}"

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
  ARCHIVE_DIR="$PAGES_UPDATES_DIR"
fi

if [[ "$INPUT_PATH" != *.zip && "$INPUT_PATH" != *.app ]]; then
  echo "error: $INPUT_PATH is not a .zip or .app - pass the notarized archive Xcode Cloud produced, or the .app extracted from it" >&2
  exit 1
fi

if [[ "$INPUT_PATH" == *.app ]]; then
  if [[ ! -d "$INPUT_PATH" ]]; then
    echo "error: $INPUT_PATH not found" >&2
    exit 1
  fi
else
  if [[ ! -f "$INPUT_PATH" ]]; then
    echo "error: $INPUT_PATH not found" >&2
    exit 1
  fi
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ "$INPUT_PATH" == *.app ]]; then
  APP_PATH="$INPUT_PATH"
  ZIP_PATH="$WORK_DIR/$(basename "$APP_PATH" .app).zip"
  echo "==> Zipping $APP_PATH"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
else
  ZIP_PATH="$INPUT_PATH"
  echo "==> Expanding $ZIP_PATH"
  ditto -x -k "$ZIP_PATH" "$WORK_DIR"
  EXPANDED_APPS=("$WORK_DIR"/*.app)
  if [[ ${#EXPANDED_APPS[@]} -ne 1 ]]; then
    echo "error: expected exactly one .app in $ZIP_PATH, found ${#EXPANDED_APPS[@]}" >&2
    exit 1
  fi
  APP_PATH="${EXPANDED_APPS[0]}"
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

if $RC_MODE; then
  # Seed the throwaway archive dir from the real update history so delta
  # patches generated for this RC look like what a real release would
  # produce. This is a read-only copy - RC runs never write back to
  # ../abeam-pages.
  echo "==> Seeding RC archive dir from $PAGES_UPDATES_DIR"
  cp -R "$PAGES_UPDATES_DIR/." "$ARCHIVE_DIR/" 2>/dev/null || true
  rm -rf "$ARCHIVE_DIR/old_updates"
else
  echo "==> Verifying $PAGES_DIR is clean"
  PAGES_STATUS="$(cd "$PAGES_DIR" && jj status --no-pager 2>&1)"
  if ! grep -q 'The working copy has no changes.' <<< "$PAGES_STATUS"; then
    echo "error: $PAGES_DIR has uncommitted changes - resolve those before releasing" >&2
    echo "$PAGES_STATUS" >&2
    exit 1
  fi
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
  --download-url-prefix "$PAGES_BASE_URL/" \
  --release-notes-url-prefix "$PAGES_BASE_URL/" \
  "$ARCHIVE_DIR"

# Superseded archives generate_appcast moves here are still recoverable from
# their own original GitHub Release if a delta ever needs recomputing from
# scratch, so there's no reason to carry them forward forever in a
# git-backed host - that's the same "extra files nobody asked for" problem
# this setup exists to avoid.
rm -rf "$ARCHIVE_DIR/old_updates"

if $RC_MODE; then
  # nullglob means *.delta expands to nothing when no deltas were generated.
  UPLOAD_FILES=("$ARCHIVE_DIR"/*.zip "$ARCHIVE_DIR"/*.delta "$ARCHIVE_DIR"/*.md "$ARCHIVE_DIR"/*.html "$ARCHIVE_DIR"/*.txt "$ARCHIVE_DIR/appcast.xml")
  echo "==> Uploading Sparkle assets to GitHub release $TAG (RC - throwaway, for manual testing only)"
  printf '    %s\n' "${UPLOAD_FILES[@]##*/}"
  gh release upload "$TAG" \
    --repo "$REPO" \
    --clobber \
    "${UPLOAD_FILES[@]}"
else
  BRIDGE_FILES=("$ARCHIVE_DIR/$ZIP_NAME" "$ARCHIVE_DIR/appcast.xml")
  if [[ -n "$NOTES_PATH" ]]; then
    BRIDGE_FILES+=("$ARCHIVE_DIR/$NOTES_NAME")
  fi
  echo "==> Uploading current zip + appcast.xml bridge to GitHub release $TAG"
  printf '    %s\n' "${BRIDGE_FILES[@]##*/}"
  gh release upload "$TAG" \
    --repo "$REPO" \
    --clobber \
    "${BRIDGE_FILES[@]}"

  echo "==> Committing and pushing $PAGES_DIR"
  (
    cd "$PAGES_DIR"
    jj describe -m "Sparkle: publish ${APP_NAME} ${VERSION} (build ${BUILD})"
    jj bookmark set gh-pages -r @
    jj git push --bookmark gh-pages
    jj new
  )
fi

echo "==> Done: https://github.com/$REPO/releases/tag/$TAG"
if $RC_MODE; then
  echo "    (prerelease - not visible as \"latest\", not offered via Sparkle)"
else
  echo "    Sparkle feed: $PAGES_BASE_URL/appcast.xml"
fi
