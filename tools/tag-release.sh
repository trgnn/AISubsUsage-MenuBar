#!/usr/bin/env bash
#
# tag-release.sh — close a milestone: set the app version and lay an annotated tag.
#
# Usage:
#   tools/tag-release.sh v1.1 "Short milestone description"
#
# What it does, in order:
#   1. Validates the version (v{major}.{minor}) and that the tag is free.
#   2. Requires a clean working tree, so the release commit only carries the bump.
#   3. Sets CFBundleShortVersionString in packaging/Info.plist (the source of truth)
#      and commits it as "Release vX.Y". Skipped when the plist already says so.
#   4. Lays an annotated tag on HEAD.
#
# It never pushes. Send the milestone up yourself when ready:
#   git push --follow-tags
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/packaging/Info.plist"

VERSION="${1:-}"
MESSAGE="${2:-}"

if [[ -z "$VERSION" || -z "$MESSAGE" ]]; then
  echo "usage: tools/tag-release.sh v<major>.<minor> \"milestone description\"" >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like v1.2 (got '$VERSION')" >&2
  exit 1
fi

if git -C "$ROOT" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  echo "error: tag $VERSION already exists" >&2
  exit 1
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: working tree not clean — commit or stash first so the" >&2
  echo "       release commit only contains the version bump." >&2
  exit 1
fi

current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [[ "$current" != "${VERSION#v}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$PLIST"
  git -C "$ROOT" add "$PLIST"
  git -C "$ROOT" commit -m "Release $VERSION"
fi
git -C "$ROOT" tag -a "$VERSION" -m "$MESSAGE"

echo "Tagged $VERSION on $(git -C "$ROOT" rev-parse --short HEAD)."
echo "Push when ready:  git push --follow-tags"
