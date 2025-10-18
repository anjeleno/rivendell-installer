#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
OFFLINE_DIR="$ROOT_DIR/installer/offline"
DIST_DIR="$ROOT_DIR/dist"

mkdir -p "$DIST_DIR"

if ! command -v makeself >/dev/null 2>&1; then
  echo "makeself not found. Install it (sudo apt install makeself) and retry." >&2
  exit 1
fi

VERSION="0.1.1"
DATE="$(date +%Y%m%d)"
OUT="$DIST_DIR/rivendell-installer-$VERSION-$DATE.run"

makeself --gzip \
  "$OFFLINE_DIR" \
  "$OUT" \
  "Rivendell Offline Installer" \
  bash ./driver.sh

echo "Created $OUT"
