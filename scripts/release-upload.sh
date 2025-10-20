#!/usr/bin/env bash
set -euo pipefail

# Upload artifacts from dist/ to a GitHub Release for the given tag.
# Usage:
#   scripts/release-upload.sh v0.1.1-20251019
#
# Auth options:
#   1) GitHub CLI (gh) installed and authenticated (gh auth login)
#   2) Environment token GH_TOKEN or GITHUB_TOKEN (with repo scope) for API calls
#
# The script will prefer gh if available; otherwise it will use curl with the token.

TAG=${1:-}
if [[ -z "${TAG}" ]]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT/dist"

# Prepare checksums
sha256sum rivendell-*.run | tee SHA256SUMS.txt
ASSETS=(rivendell-*.run SHA256SUMS.txt)

if command -v gh >/dev/null 2>&1; then
  echo "Using gh CLI to publish assets to $TAG..."
  if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "Creating release $TAG..."
    gh release create "$TAG" --title "$TAG" --notes "Rivendell Offline Installer release for $TAG"
  else
    echo "Release $TAG already exists. Uploading assets..."
  fi
  echo "Uploading: ${ASSETS[*]}"
  gh release upload "$TAG" --clobber "${ASSETS[@]}"
  echo "Done. Release: $(gh release view "$TAG" --json url -q .url)"
  exit 0
fi

# Fallback to GitHub REST API using a token
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
# Attempt to auto-discover a PAT from ~/.git-credentials if not provided
if [[ -z "${TOKEN}" && -f "$HOME/.git-credentials" ]]; then
  # Avoid leaking credentials if xtrace is enabled
  _xtrace_state=$(set +o | grep xtrace || true)
  set +x 2>/dev/null || true
  CRED_LINE=$(grep -m1 'github.com' "$HOME/.git-credentials" || true)
  if [[ -n "$CRED_LINE" ]]; then
    # Expected format: https://USERNAME:TOKEN@github.com
  DISCOVERED_TOKEN=$(echo "$CRED_LINE" | sed -E 's#https://[^:]+:([^@]+)@github.com.*#\1#')
    if [[ -n "$DISCOVERED_TOKEN" && "$DISCOVERED_TOKEN" != "$CRED_LINE" ]]; then
      TOKEN="$DISCOVERED_TOKEN"
      echo "Using token from ~/.git-credentials for github.com"
    fi
  fi
  # Restore xtrace state
  eval "$_xtrace_state"
fi
if [[ -z "${TOKEN}" ]]; then
  echo "Error: Neither gh CLI is installed nor GH_TOKEN/GITHUB_TOKEN is set." >&2
  echo "Provide a token with 'repo' scope: export GH_TOKEN=YOUR_TOKEN" >&2
  exit 1
fi

# Derive owner/repo from git remote
ORIGIN_URL=$(git -C "$REPO_ROOT" remote get-url origin)
OWNER_REPO=$(echo "$ORIGIN_URL" | sed -E 's#.*github.com[:/]+([^/]+/[^/.]+)(\.git)?$#\1#')
if [[ -z "$OWNER_REPO" || "$OWNER_REPO" == "$ORIGIN_URL" ]]; then
  echo "Error: Could not determine owner/repo from origin URL: $ORIGIN_URL" >&2
  exit 1
fi

API="https://api.github.com/repos/$OWNER_REPO"
HDRS=( -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" )

echo "Ensuring release $TAG exists via API..."
set +e
REL_JSON=$(curl -fsS "${HDRS[@]}" "$API/releases/tags/$TAG")
RC=$?
set -e
if [[ $RC -ne 0 || -z "$REL_JSON" ]]; then
  echo "Creating release $TAG via API..."
  REL_JSON=$(curl -fsS -X POST "${HDRS[@]}" "$API/releases" \
    -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"body\":\"Rivendell Offline Installer release for $TAG\"}")
fi

# Extract id and upload_url using python3 (preferred) or sed fallback
if command -v python3 >/dev/null 2>&1; then
  REL_ID=$(printf '%s' "$REL_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
  UPLOAD_URL=$(printf '%s' "$REL_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["upload_url"])')
else
  REL_ID=$(echo "$REL_JSON" | sed -n 's/.*"id":\s*\([0-9][0-9]*\).*/\1/p' | head -n1)
  UPLOAD_URL=$(echo "$REL_JSON" | sed -n 's/.*"upload_url":\s*"\([^"]*\)".*/\1/p')
fi

UPLOAD_URL_BASE=${UPLOAD_URL%\{*}
if [[ -z "$REL_ID" || -z "$UPLOAD_URL_BASE" ]]; then
  echo "Error: Failed to parse release id or upload_url from API response." >&2
  exit 1
fi

# Fetch existing assets so we can delete on clobber
ASSETS_JSON=$(curl --http1.1 -fsS "${HDRS[@]}" "$API/releases/$REL_ID/assets?per_page=100" || echo "[]")

delete_asset_if_exists() {
  local fname="$1"
  local aid
  # Quick check: if ASSETS_JSON looks empty, skip parsing
  if [[ -z "$ASSETS_JSON" || "$ASSETS_JSON" == "[]"* ]]; then
    aid=""
  elif command -v python3 >/dev/null 2>&1; then
  aid=$(printf '%s' "$ASSETS_JSON" | python3 - "$fname" <<'PY'
import sys,json
try:
  assets=json.load(sys.stdin)
  name=sys.argv[1]
  for a in assets:
    if a.get('name')==name:
      print(a.get('id',''))
      break
except Exception:
  pass
PY
  )
  else
    aid=$(echo "$ASSETS_JSON" | awk -v name="$fname" '/"id":/ {id=$2} /"name":/ {gsub(/[",]/,""); if ($2==name) {print id}}' | head -n1 || true)
  fi
  if [[ -n "$aid" ]]; then
    echo "Deleting existing asset $fname (id $aid)..."
  curl --http1.1 -fsS -X DELETE "${HDRS[@]}" "$API/releases/assets/$aid" >/dev/null || true
  fi
}

for f in "${ASSETS[@]}"; do
  [[ -f "$f" ]] || { echo "Skipping missing $f"; continue; }
  delete_asset_if_exists "$(basename "$f")"
  echo "Uploading $f..."
  curl --http1.1 -fsS -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" \
    "$UPLOAD_URL_BASE?name=$(basename "$f")" >/dev/null
done

echo "Done. Release URL: https://github.com/$OWNER_REPO/releases/tag/$TAG"