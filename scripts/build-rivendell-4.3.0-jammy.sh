#!/usr/bin/env bash
set -euo pipefail
trap 'code=$?; echo "[FATAL] build script failed at line $LINENO with exit $code" >&2; exit $code' ERR

cleanup() {
  echo "[INFO] Cleaning up mounts..." >&2
  umount -lf "$CHROOT_DIR/output" 2>/dev/null || true
  umount -lf "$CHROOT_DIR$CCACHE_DIR_CHROOT" 2>/dev/null || true
  umount -lf "$CHROOT_DIR/proc" 2>/dev/null || true
  umount -lf "$CHROOT_DIR/sys" 2>/dev/null || true
  umount -lf "$CHROOT_DIR/dev" 2>/dev/null || true
}
trap cleanup EXIT

# Build Rivendell 4.3.0 .deb packages targeting Ubuntu 22.04 (jammy)
# using a debootstrap chroot on this host. No containers required.
# Results are copied into installer/offline/packages/22.04.

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root (sudo)." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
OUT_DIR="$REPO_ROOT/installer/offline/packages/22.04"
CHROOT_DIR="/srv/jammy-riv-build"
CCACHE_DIR_HOST="/srv/jammy-ccache"
CCACHE_DIR_CHROOT="/ccache"
SRC_DIR="/build/rivendell"

mkdir -p "$OUT_DIR" "$CCACHE_DIR_HOST"

echo "[INFO] Installing debootstrap if needed..."
apt-get update -qq
apt-get install -y debootstrap ca-certificates gnupg

if [[ ! -d "$CHROOT_DIR" ]]; then
  echo "[INFO] Creating jammy chroot at $CHROOT_DIR ..."
  debootstrap --variant=buildd jammy "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu
fi

echo "[INFO] Wiring chroot mounts and network..."
cp -f /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf" || true
mountpoint -q "$CHROOT_DIR/proc" || mount -t proc proc "$CHROOT_DIR/proc"
mountpoint -q "$CHROOT_DIR/sys" || mount --rbind /sys "$CHROOT_DIR/sys"
mountpoint -q "$CHROOT_DIR/dev" || mount --rbind /dev "$CHROOT_DIR/dev"

# Bind output dir so we can copy results out easily
mkdir -p "$CHROOT_DIR/output" "$CHROOT_DIR$CCACHE_DIR_CHROOT"
mountpoint -q "$CHROOT_DIR/output" || mount --bind "$OUT_DIR" "$CHROOT_DIR/output"
mountpoint -q "$CHROOT_DIR$CCACHE_DIR_CHROOT" || mount --bind "$CCACHE_DIR_HOST" "$CHROOT_DIR$CCACHE_DIR_CHROOT"

echo "[INFO] Configuring apt sources inside chroot..."
cat >"$CHROOT_DIR/etc/apt/sources.list" <<'SL'
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
SL

cat >"$CHROOT_DIR/setup-build.sh" <<'CH'
#!/usr/bin/env bash
set -euo pipefail
trap 'code=$?; echo "[FATAL] chroot build failed at line $LINENO with exit $code" >&2; exit $code' ERR
export DEBIAN_FRONTEND=noninteractive
PRECHECK="${PRECHECK:-0}"
RESUME="${RESUME:-0}"

# Conservative apt options to avoid long stalls
APT_OPTS=(
  -o Acquire::http::Timeout=20
  -o Acquire::https::Timeout=20
  -o Acquire::Retries=1
  -o Dpkg::Use-Pty=0
)

# Avoid locale noise during precheck by using C.UTF-8 (present by default)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

if ! timeout 120s apt-get "${APT_OPTS[@]}" update; then
  echo "[ERROR] apt-get update failed or timed out in chroot (network/mirror issue)." >&2
  exit 90
fi

# Speed up apt/dpkg and compiles, and ensure core build toolchain and deps
if [[ "$PRECHECK" == "1" ]]; then
  echo "[INFO] PRECHECK: Skipping package installs to avoid long operations."
else
  if ! timeout 900s apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    eatmydata ccache pkg-config dpkg-dev \
    git build-essential debhelper devscripts fakeroot \
    rsync \
    autoconf automake libtool autoconf-archive \
    qtbase5-dev qttools5-dev-tools libqt5sql5-mysql libqt5webkit5-dev \
    libexpat1 libexpat1-dev libssl-dev \
    libsamplerate0-dev libsndfile1-dev libcdparanoia-dev \
    libcoverart-dev libdiscid-dev libmusicbrainz5-dev \
    libid3-3.8.3-dev libtag1-dev libcurl4-gnutls-dev libpam0g-dev \
    libsoundtouch-dev libjack-jackd2-dev libasound2-dev \
    libflac-dev libflac++-dev libmp3lame-dev libmad0-dev libtwolame-dev \
    libmagick++-6.q16-dev \
    libxml2-utils xsltproc \
    python3 python3-pycurl python3-serial python3-requests python3-mysqldb \
    apache2; then
    echo "[ERROR] apt-get install of build dependencies failed or timed out." >&2
    exit 91
  fi
fi

# Quiet locale warnings (optional)
# Avoid locales install; rely on C.UTF-8 set above
sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen en_US.UTF-8 || true
update-locale LANG=en_US.UTF-8 || true

export CCACHE_DIR="/ccache"
export CC="ccache gcc"
export CXX="ccache g++"
export MAKEFLAGS="-j$(nproc)"
export EATMYDATA=1

rm -rf /build
mkdir -p /build
cd /build

echo "[INFO] Cloning Rivendell v4.3.0..."
git clone --branch v4.3.0 --depth 1 https://github.com/ElvishArtisan/rivendell.git
cd rivendell

if [[ "$PRECHECK" != "1" ]]; then
  echo "[INFO] Prepare build system..."
  if [[ -x ./configure_build.sh ]]; then ./configure_build.sh || true; fi
  if [[ ! -x ./configure ]]; then autoreconf -i; fi

  echo "[INFO] Configure with docs disabled..."
  ./configure --prefix=/usr \
    --libdir=/usr/lib \
    --libexecdir=/var/www/rd-bin \
    --sysconfdir=/etc/apache2/conf-enabled \
    --enable-rdxport-debug \
    --disable-docbook \
    MUSICBRAINZ_LIBS="-ldiscid -lmusicbrainz5cc -lcoverartcc"
fi

# Ensure Debian packaging disables docs + remove opsguide/manpages
if [[ -f debian/rules ]]; then
  sed -i 's|\./configure |./configure --disable-docbook |' debian/rules || true
  sed -i -E '/opsguide(\.pdf|\b)/Id' debian/rules || true
  sed -i -E '/rivendell-opsguide/Id' debian/rules || true
  sed -i -E '/\/(docs|html)\//Id' debian/rules || true
  sed -i -E '/\/usr\/share\/man\/man[0-9]\//Id' debian/rules || true
  sed -i -E '/^\s*(mv|install)\s+.*man\//Id' debian/rules || true
fi

if [[ -f debian/control ]]; then
  awk 'BEGIN{skip=0} { if ($0 ~ /^Package: rivendell-opsguide$/) {skip=1} if (!skip) print $0; if (skip && $0 ~ /^Package: /) {skip=0; print $0} }' debian/control > debian/control.new || true
  if grep -q '^Package: rivendell-opsguide' debian/control; then mv debian/control.new debian/control; else rm -f debian/control.new; fi
fi

if compgen -G "debian/*.install" > /dev/null; then
  sed -i -E '/opsguide/Id' debian/*.install || true
  sed -i -E '/\/(docs|html)\//Id' debian/*.install || true
  sed -i -E '/\/usr\/share\/man\/man[0-9]\//Id' debian/*.install || true
fi
if compgen -G "debian/*opsguide*.install" > /dev/null; then rm -f debian/*opsguide*.install || true; fi
if compgen -G "debian/*.manpages" > /dev/null; then rm -f debian/*.manpages || true; fi

mkdir -p debian/tmp/usr/share/rivendell || true
touch debian/tmp/usr/share/rivendell/opsguide.pdf || true

if [[ "$PRECHECK" == "1" ]]; then
  if command -v dpkg-checkbuilddeps >/dev/null 2>&1; then
    echo "[INFO] Checking build-deps (dpkg-checkbuilddeps)..."
    if ! dpkg-checkbuilddeps; then
      echo "[ERROR] Missing build dependencies according to debian/control. See above output." >&2
      exit 3
    fi
  else
    echo "[INFO] dpkg-checkbuilddeps not present in PRECHECK; skipping dependency validation."
  fi
  echo "[OK] Precheck complete: apt reachable, sources cloned. Ready to build." >&2
  exit 0
fi

echo "[INFO] Build .debs for jammy..."
export DEB_BUILD_OPTIONS="nodoc nocheck parallel=$(nproc)"
dpkg_args=(-b -us -uc)
if [[ "$RESUME" == "1" ]]; then dpkg_args=(-nc "${dpkg_args[@]}"); fi
if ! eatmydata dpkg-buildpackage "${dpkg_args[@]}"; then
  echo "[ERROR] dpkg-buildpackage failed" >&2
  exit 4
fi

echo "[INFO] Copying .debs to /output ..."
shopt -s nullglob
artifacts=(/build/*.deb)
if (( ${#artifacts[@]} == 0 )); then
  echo "[ERROR] No .deb artifacts found in /build after dpkg-buildpackage" >&2
  exit 2
fi
# Require the core package to exist to avoid partial-success situations
if ! compgen -G "/build/rivendell_*_amd64.deb" > /dev/null; then
  echo "[ERROR] Core rivendell_* package missing; treat build as failed." >&2
  ls -l /build || true
  exit 5
fi
cp -f /build/*.deb /output/
shopt -u nullglob

echo "[DONE] Jammy .debs exported."
CH

chmod +x "$CHROOT_DIR/setup-build.sh"

echo "[INFO] Running build in chroot..."
if [[ "${PRECHECK:-0}" == "1" ]]; then
  echo "[INFO] PRECHECK mode enabled: will stop after checking build-deps and preparing sources."
fi
chroot "$CHROOT_DIR" /usr/bin/env PRECHECK="${PRECHECK:-0}" /bin/bash /setup-build.sh

echo "[INFO] Cleaning up mounts..."
umount -lf "$CHROOT_DIR/output" || true
umount -lf "$CHROOT_DIR$CCACHE_DIR_CHROOT" || true
umount -lf "$CHROOT_DIR/proc" || true
umount -lf "$CHROOT_DIR/sys" || true
umount -lf "$CHROOT_DIR/dev" || true

echo "[DONE] Rivendell 4.3.0 .debs placed in: $OUT_DIR"
