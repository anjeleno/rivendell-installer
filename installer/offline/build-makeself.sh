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

# Prepare a temporary staging area for the base installer; exclude MATE subfolders entirely
STAGE_BASE="$(mktemp -d)"
rsync -a --exclude 'packages/*/mate' "$OFFLINE_DIR/" "$STAGE_BASE/"

# Build base installer (no MATE)
BASE_OUT="$DIST_DIR/rivendell-installer-$VERSION-$DATE.run"
makeself --gzip \
  "$STAGE_BASE" \
  "$BASE_OUT" \
  "Rivendell Offline Installer" \
  bash ./driver.sh
echo "Created $BASE_OUT"

# Build per-series MATE bundles if directories exist
build_mate_bundle() {
  local series_dir="$1"
  local src_dir="$OFFLINE_DIR/packages/$series_dir/mate"
  [[ -d "$src_dir" ]] || return 0
  local stage_mate
  stage_mate="$(mktemp -d)"
  mkdir -p "$stage_mate/packages/$series_dir/mate"
  echo "[INFO] Building MATE bundle for series $series_dir"
  cp "$src_dir"/*.deb "$stage_mate/packages/$series_dir/mate/" 2>/dev/null || true
  # Include a tiny runner that installs from this cache
  cat > "$stage_mate/install-mate.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SERIES="$(ls packages | head -n1)"
DEB_DIR="packages/$SERIES/mate"
echo "Installing MATE from local cache: $DEB_DIR"
apt-get -y -o Dir::Cache::Archives="$DEB_DIR" --no-download install ubuntu-mate-desktop lightdm dbus-x11 \
  || apt-get -y -o Dir::Cache::Archives="$DEB_DIR" --no-download install mate-desktop-environment lightdm dbus-x11 \
  || { dpkg -i "$DEB_DIR"/*.deb || true; apt-get -y -f install; }
echo "Setting LightDM as default display manager"
apt-get -y install lightdm debconf-utils || true
echo "lightdm shared/default-x-display-manager select lightdm" | debconf-set-selections || true
dpkg-reconfigure -f noninteractive lightdm || true
echo "MATE installation done."
EOS
  chmod +x "$stage_mate/install-mate.sh"
  local mate_out="$DIST_DIR/rivendell-mate-bundle-$series_dir-$VERSION-$DATE.run"
  makeself --gzip "$stage_mate" "$mate_out" "Rivendell MATE Bundle $series_dir" bash ./install-mate.sh
  echo "Created $mate_out"
}

build_mate_bundle 22.04 || true
build_mate_bundle 24.04 || true

echo "All artifacts created in $DIST_DIR"
