#!/usr/bin/env bash
set -euo pipefail

# Upload artifacts from dist/ to a GitHub Release for the given tag.
# Requires: gh (GitHub CLI) authenticated to the repository.
# Usage: scripts/release-upload.sh v0.1.1-20251019

TAG=${1:-}
if [[ -z "${TAG}" ]]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh (GitHub CLI) not installed. Install and run 'gh auth login'." >&2
  exit 1
fi

# Ensure release exists (create if missing)
if ! gh release view "$TAG" >/dev/null 2>&1; then
  echo "Creating release $TAG..."
  gh release create "$TAG" \
    --title "$TAG" \
    --notes "Rivendell Offline Installer release for $TAG"
else
  echo "Release $TAG already exists. Uploading assets..."
fi

cd "$(dirname "$0")/../dist"

sha256sum rivendell-*.run | tee SHA256SUMS.txt

# Upload assets
ASSETS=(rivendell-*.run SHA256SUMS.txt)

echo "Uploading: ${ASSETS[*]}"
# Use --clobber to overwrite if assets already present
if ! gh release upload "$TAG" --clobber "${ASSETS[@]}"; then
  echo "Failed to upload assets to release $TAG" >&2
  exit 1
fi

echo "Done. Release: $(gh release view "$TAG" --json url -q .url)"