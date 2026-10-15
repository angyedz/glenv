#!/bin/sh
# Clean-room test: install glenv into a pristine Alpine chroot, verify, then
# uninstall and verify again. This is what CI runs; locally it needs sudo.
#
#   sh tests/chroot-cleanroom.sh
#
# Environment:
#   CHROOT_DIR            where to build the test rootfs (default /tmp/glenv-chroot-test)
#   GLENV_TEST_KEEP=1     keep the chroot after a successful run (for inspection)
#   ALPINE_VER            minirootfs version (default 3.24.2)
#   GLENV_TEST_PREFIX     install prefix inside chroot (default /srv/glenv-test)
set -u

ROOTFS="${CHROOT_DIR:-/tmp/glenv-chroot-test}"
ALPINE_VER="${ALPINE_VER:-3.24.2}"
ALPINE_REL="v$(printf '%s' "$ALPINE_VER" | awk -F. '{print $1 "." $2}')"
TEST_PREFIX="${GLENV_TEST_PREFIX:-/srv/glenv-test}"
URL="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_REL/releases/x86_64/alpine-minirootfs-$ALPINE_VER-x86_64.tar.gz"
TREE=$(cd "$(dirname "$0")/.." && pwd)
TARBALL="${TMPDIR:-/tmp}/alpine-minirootfs-$ALPINE_VER-x86_64.tar.gz"
LOGDIR="${TMPDIR:-/tmp}"
FAILS=0

log()  { printf '[cleanroom] %s\n' "$1"; }
pass() { printf '[cleanroom]   ok: %s\n' "$1"; }
fail() { printf '[cleanroom]   FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert() {   # assert "description" <command...>
    _desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$_desc"; else fail "$_desc"; fi
}

# ---- elevate once: everything below runs as root -------------------------
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || { echo "need root (no sudo)"; exit 1; }
    sudo -n true 2>/dev/null || { echo "need root: run 'sudo -v' first (or passwordless sudo, as in CI)"; exit 1; }
    exec sudo -n env CHROOT_DIR="$ROOTFS" ALPINE_VER="$ALPINE_VER" \
        GLENV_TEST_PREFIX="$TEST_PREFIX" GLENV_TEST_KEEP="${GLENV_TEST_KEEP:-0}" \
        sh "$0" "$@"
fi

# ---- cleanup: unmount everything under $ROOTFS on exit -------------------
cleanup() {
    for m in $(mount 2>/dev/null | grep " on $ROOTFS/" | awk '{print $3}' | sort -r); do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
    done
    if [ "$FAILS" -eq 0 ] && [ "${GLENV_TEST_KEEP:-0}" != 1 ]; then
        rm -rf "$ROOTFS"
    else
        log "chroot kept at $ROOTFS (failures=$FAILS, GLENV_TEST_KEEP=${GLENV_TEST_KEEP:-0})"
    fi
}
trap cleanup EXIT INT TERM

# ---- 1. rootfs ------------------------------------------------------------
if [ ! -s "$TARBALL" ]; then
    log "downloading minirootfs $ALPINE_VER"
    wget -q -T 60 -O "$TARBALL.part" "$URL" || { echo "cannot download $URL"; exit 1; }
    mv "$TARBALL.part" "$TARBALL"
fi

# preserve the .deb cache across runs (first run downloads, later runs fast)
SAVED=""
if [ -d "$ROOTFS$TEST_PREFIX/debs" ]; then
    SAVED=$(mktemp -d)
    cp -a "$ROOTFS$TEST_PREFIX/debs/." "$SAVED/" 2>/dev/null || true
fi

log "building rootfs at $ROOTFS"
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xzf "$TARBALL" -C "$ROOTFS" || { echo "cannot extract minirootfs"; exit 1; }
if [ -n "$SAVED" ]; then
    mkdir -p "$ROOTFS$TEST_PREFIX/debs"
    cp -a "$SAVED/." "$ROOTFS$TEST_PREFIX/debs/" 2>/dev/null || true
    rm -rf "$SAVED"
    log "reused cached .deb packages"
fi

cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
printf 'https://dl-cdn.alpinelinux.org/alpine/%s/main\nhttps://dl-cdn.alpinelinux.org/alpine/%s/community\n' \
    "$ALPINE_REL" "$ALPINE_REL" > "$ROOTFS/etc/apk/repositories"
for m in proc sys dev; do
    mkdir -p "$ROOTFS/$m"
    mount --bind "/$m" "$ROOTFS/$m" || { echo "cannot bind /$m"; exit 1; }
done

# ---- 2. copy only what a git clone would contain --------------------------
T="$ROOTFS/root/glenv"
mkdir -p "$T/bin" "$T/lib" "$T/src/shim"
cp "$TREE/install.sh"                  "$T/"
cp "$TREE/bin/glenv"                   "$T/bin/"
cp "$TREE/lib/glenv-wayland-filter.so"  "$T/lib/"
cp "$TREE/src/shim/glenv-wayland-filter.c" "$T/src/shim/"
chmod 755 "$T/install.sh" "$T/bin/glenv"

# ---- 3. install (line mode: 3=full preset, y=confirm) ---------------------
log "install: full preset, line mode"
printf '3\ny\ny\n' | chroot "$ROOTFS" env GLENV_PREFIX="$TEST_PREFIX" sh /root/glenv/install.sh \
    > "$LOGDIR/glenv-cleanroom-install.log" 2>&1
_rc=$?
INSTALL_LOG="$LOGDIR/glenv-cleanroom-install.log"
if [ "$_rc" -eq 0 ]; then pass "install exit code 0"; else fail "install exit code $_rc"; fi
assert "install log says finished"        grep -q "installation finished" "$INSTALL_LOG"
assert "install log says 9/9 checks"      grep -q "9/9 checks passed" "$INSTALL_LOG"
assert "Debian signed index verified"       grep -q "InRelease signature, freshness, index hash" "$INSTALL_LOG"
assert "sha256 verified message"          grep -q "sha256 verified" "$INSTALL_LOG"
assert "zstd installed for Debian archives" chroot "$ROOTFS" sh -c 'command -v zstd >/dev/null'
assert "glibc loader installed"           test -s "$ROOTFS/lib/ld-linux-x86-64.so.2"
assert "/lib64 symlink created"           test -L "$ROOTFS/lib64/ld-linux-x86-64.so.2"
assert "ld.so.cache non-empty"            test -s "$ROOTFS/etc/ld.so.cache"
assert "fstab has bind mounts"            grep -q " /usr/lib/x86_64-linux-gnu " "$ROOTFS/etc/fstab"
assert "profile.d present"                test -f "$ROOTFS/etc/profile.d/glibc-env.sh"
assert "Wayland filter preloaded"         grep -q "glenv-wayland-filter" "$ROOTFS/etc/ld.so.preload"
assert "glenv binary present in custom prefix" test -x "$ROOTFS$TEST_PREFIX/bin/glenv"
assert "custom prefix ownership marker"    grep -qx "glenv managed prefix" "$ROOTFS$TEST_PREFIX/.glenv-prefix"
chroot "$ROOTFS" "$TEST_PREFIX/bin/glenv" doctor > "$LOGDIR/glenv-cleanroom-doctor.log" 2>&1
assert "glenv detects custom prefix from executable" grep -q "sysroot: $TEST_PREFIX/sysroot" "$LOGDIR/glenv-cleanroom-doctor.log"
if chroot "$ROOTFS" "$TEST_PREFIX/sysroot/usr/bin/hello" 2>/dev/null | grep -q "Hello, world!"; then
    pass "direct glibc exec (hello)"
else
    fail "direct glibc exec (hello)"
fi

# ---- 4. uninstall ---------------------------------------------------------
log "uninstall (keep prefix)"
printf 'y\n' | chroot "$ROOTFS" env GLENV_PREFIX="$TEST_PREFIX" sh /root/glenv/install.sh --uninstall \
    > "$LOGDIR/glenv-cleanroom-uninstall.log" 2>&1
_rc=$?
UNINST_LOG="$LOGDIR/glenv-cleanroom-uninstall.log"
if [ "$_rc" -eq 0 ]; then pass "uninstall exit code 0"; else fail "uninstall exit code $_rc"; fi
assert "uninstall log says finished"      grep -q "uninstall finished" "$UNINST_LOG"
assert "uninstall log all checks green"   grep -qE "[0-9]/[0-9] checks passed" "$UNINST_LOG"
assert "no glenv fstab lines"             sh -c "! grep -q '^$TEST_PREFIX/' $ROOTFS/etc/fstab"
assert "bind mounts are gone"             sh -c "! mount | grep -q ' on $ROOTFS/usr/lib/x86_64-linux-gnu type'"
assert "ld.so.preload has no filter"      sh -c "! grep -q glenv-wayland-filter $ROOTFS/etc/ld.so.preload"
assert "ld.so.conf.d entry removed"       test ! -e "$ROOTFS/etc/ld.so.conf.d/glibc-env.conf"
assert "ld.so.cache removed"              test ! -e "$ROOTFS/etc/ld.so.cache"
assert "profile.d removed"                test ! -e "$ROOTFS/etc/profile.d/glibc-env.sh"
assert "loader removed"                   test ! -e "$ROOTFS/lib/ld-linux-x86-64.so.2"
assert "/lib64 symlink removed"           test ! -e "$ROOTFS/lib64/ld-linux-x86-64.so.2"
assert "custom prefix kept (no --purge)"   test -d "$ROOTFS$TEST_PREFIX"

# ---- 5. purge -------------------------------------------------------------
log "uninstall --purge (delete prefix)"
printf 'y\n' | chroot "$ROOTFS" env GLENV_PREFIX="$TEST_PREFIX" sh /root/glenv/install.sh --uninstall --purge \
    > "$LOGDIR/glenv-cleanroom-purge.log" 2>&1
_rc=$?
PURGE_LOG="$LOGDIR/glenv-cleanroom-purge.log"
if [ "$_rc" -eq 0 ]; then pass "purge exit code 0"; else fail "purge exit code $_rc"; fi
assert "purge log says finished"          grep -q "uninstall finished" "$PURGE_LOG"
assert "custom prefix deleted"             test ! -d "$ROOTFS$TEST_PREFIX"

# ---- summary --------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
    echo "[cleanroom] ALL PASSED"
    exit 0
else
    echo "[cleanroom] $FAILS FAILURE(S) — logs: $INSTALL_LOG $UNINST_LOG $PURGE_LOG"
    exit 1
fi
