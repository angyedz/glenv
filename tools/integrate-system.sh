#!/bin/sh
# Integrate glenv glibc environment into the system (Alpine/musl + OpenRC).
# After this any glibc binary runs directly:
#   kernel -> /lib64/ld-linux-x86-64.so.2 -> /etc/ld.so.cache -> sysroot.
# musl does not read ld.so.cache and does not use */x86_64-linux-gnu paths — no conflict.
set -e

PREFIX="${GLENV_PREFIX:-/opt/glibc-env}"
while [ "$PREFIX" != "/" ]; do case "$PREFIX" in */) PREFIX=${PREFIX%/} ;; *) break ;; esac; done
case "$PREFIX" in /*) ;; *) echo "GLENV_PREFIX must be absolute" >&2; exit 2 ;; esac
case "$PREFIX" in *[!A-Za-z0-9_./-]*|*/../*|*/..|/|/opt|/usr|/home|/var|/etc|/root|/tmp|/lib|/bin|/sbin|/srv|/mnt|/media)
    echo "unsafe GLENV_PREFIX: $PREFIX" >&2; exit 2 ;;
esac
SYS="$PREFIX/sysroot"
[ -f /etc/alpine-release ] || { echo "glenv integration supports Alpine Linux only" >&2; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "this glenv build supports x86_64 only" >&2; exit 1; }
for _musl in /lib/ld-musl-*.so.1; do
    [ -e "$_musl" ] && break
done
[ -e "${_musl:-/nonexistent}" ] || { echo "musl loader not found" >&2; exit 1; }
[ -d "$SYS/usr" ] || { echo "no sysroot: $SYS (set GLENV_PREFIX)"; exit 1; }
file_size() {
    _size=$(stat -c %s "$1" 2>/dev/null) || _size=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
    case "$_size" in ''|*[!0-9]*) _size=0 ;; esac
    printf '%s' "$_size"
}

SUDO="sudo -n"
if ! $SUDO true 2>/dev/null; then
    if [ -n "$SUDO_ASKPASS" ]; then
        SUDO="sudo -A"
    else
        SUDO="sudo"
    fi
fi

echo "== 1. Mount points =="
$SUDO mkdir -p /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib/locale /usr/lib/ssl

echo "== 2. Kernel loader (ELF interpreter) =="
# /lib64/ld-linux-x86-64.so.2 -> ../lib/ld-linux-x86-64.so.2 (exists on Alpine)
# WARNING: gcompat installs its own 22KB musl shim under the same name — it lacks
# glibc 2.41 symbols ("Error relocating ... symbol not found"). Install the REAL
# glibc loader from the sysroot; shim is kept nearby as *.gcompat-shim.
if { [ -e /lib/ld-linux-x86-64.so.2 ] || [ -L /lib/ld-linux-x86-64.so.2 ]; } && \
   ! cmp -s /lib/ld-linux-x86-64.so.2 "$SYS/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"; then
    if [ -e /lib/ld-linux-x86-64.so.2.gcompat-shim ] || [ -L /lib/ld-linux-x86-64.so.2.gcompat-shim ]; then
        echo "ERROR: existing loader and backup both exist; refusing to overwrite" >&2
        exit 1
    fi
    $SUDO mv /lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2.gcompat-shim
    $SUDO cp "$SYS/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" /lib/ld-linux-x86-64.so.2
    echo "   gcompat shim replaced with real glibc loader (shim kept as *.gcompat-shim)"
elif [ ! -e /lib/ld-linux-x86-64.so.2 ] && [ ! -L /lib/ld-linux-x86-64.so.2 ]; then
    $SUDO cp "$SYS/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" /lib/ld-linux-x86-64.so.2
    echo "   installed /lib/ld-linux-x86-64.so.2"
else
    echo "   already our glibc loader"
fi

# Debian binaries carry PT_INTERP /lib64/ld-linux-x86-64.so.2 — without this
# symlink every direct glibc exec fails with "not found" (rc=127)
P64=/lib64/ld-linux-x86-64.so.2
if [ -L "$P64" ] && [ "$(readlink "$P64" 2>/dev/null)" = ../lib/ld-linux-x86-64.so.2 ]; then
    echo "   $P64 already points to glenv loader"
else
    [ -d /lib64 ] || [ -L /lib64 ] || $SUDO mkdir -p /lib64
    if [ -e "$P64" ] || [ -L "$P64" ]; then
        if [ ! -e "$P64.gcompat-shim" ] && [ ! -L "$P64.gcompat-shim" ]; then
            $SUDO mv "$P64" "$P64.gcompat-shim"
            echo "   preserved previous $P64 as $P64.gcompat-shim"
        else
            echo "   ERROR: $P64 and its backup both exist; refusing to overwrite" >&2
            exit 1
        fi
    fi
    $SUDO ln -s ../lib/ld-linux-x86-64.so.2 "$P64"
    echo "   created $P64 -> ../lib/ld-linux-x86-64.so.2"
fi

# glibc ldconfig first: busybox's `ldconfig` exits 0 without writing a glibc cache
$SUDO "$SYS/usr/sbin/ldconfig" 2>/dev/null || $SUDO ldconfig 2>/dev/null || true

echo "== 3. fstab bind mounts (persistent, picked up by OpenRC mount) =="
add_mount() {
    src="$1"; dst="$2"
    mkdir -p "$src"
    $SUDO mkdir -p "$dst"
    if awk -v s="$src" -v d="$dst" '$1 == s && $2 == d && $3 == "none" && $4 ~ /(^|,)bind(,|$)/ {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        return
    fi
    occupied=$(awk -v d="$dst" '$2 == d {print; exit}' /etc/fstab 2>/dev/null)
    if [ -n "$occupied" ] && ! printf '%s\n' "$occupied" | awk '$1 ~ /\/sysroot\// && $4 ~ /(^|,)bind(,|$)/ {found=1} END {exit !found}'; then
        echo "ERROR: fstab target $dst is already owned by another mount; not overwriting it" >&2
        return 1
    fi
    # Replace a stale glenv bind for this destination, but leave unrelated fstab entries alone.
    _fstab_tmp=$(mktemp "${TMPDIR:-/tmp}/glenv-fstab.XXXXXX") || return 1
    awk -v d="$dst" \
        '!($2 == d && $1 ~ /\/sysroot\// && $4 ~ /(^|,)bind(,|$)/)' /etc/fstab > "$_fstab_tmp" || { rm -f "$_fstab_tmp"; return 1; }
    echo "$src $dst none bind 0 0" >> "$_fstab_tmp"
    if $SUDO cp "$_fstab_tmp" /etc/fstab; then _rc=0; else _rc=$?; fi
    rm -f "$_fstab_tmp"
    return "$_rc"
}
add_mount "$SYS/usr/lib/x86_64-linux-gnu" /usr/lib/x86_64-linux-gnu
add_mount "$SYS/usr/lib/x86_64-linux-gnu" /lib/x86_64-linux-gnu
add_mount "$SYS/usr/lib64"                /usr/lib64
add_mount "$SYS/usr/lib/locale"           /usr/lib/locale
add_mount "$SYS/usr/share/i18n"           /usr/share/i18n
# GLVND vendors (EGL) and drirc: without them glibc libEGL cannot find Mesa ICD
add_mount "$SYS/usr/share/glvnd"          /usr/share/glvnd
add_mount "$SYS/usr/share/drirc.d"        /usr/share/drirc.d
$SUDO mkdir -p /usr/share/i18n /usr/share/glvnd /usr/share/drirc.d
$SUDO mount -a 2>/dev/null || true
for spec in \
    "$SYS/usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu" \
    "$SYS/usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu" \
    "$SYS/usr/lib64 /usr/lib64" \
    "$SYS/usr/lib/locale /usr/lib/locale" \
    "$SYS/usr/share/i18n /usr/share/i18n" \
    "$SYS/usr/share/glvnd /usr/share/glvnd" \
    "$SYS/usr/share/drirc.d /usr/share/drirc.d"; do
    src=${spec% *}; dst=${spec#* }
    awk -v s="$src" -v d="$dst" '$1 == s && $2 == d && $4 ~ /(^|,)bind(,|$)/ {found=1} END {exit !found}' /etc/fstab || continue
    if mount | awk -v s="$src" -v d="$dst" '$1 == s && $3 == d {found=1} END {exit !found}'; then
        continue
    fi
    if mount | awk -v d="$dst" '$3 == d {found=1} END {exit !found}'; then
        $SUDO umount "$dst" || { echo "WARNING: cannot replace old mount at $dst" >&2; continue; }
    fi
    $SUDO mount --bind "$src" "$dst"
done
echo "   mounted:"
mount | grep -E 'x86_64-linux-gnu|lib64|lib/locale|i18n' | sed 's/^/   /'

echo "== 4. ld.so.conf + ld.so.cache (glibc; musl ignores it) =="
$SUDO mkdir -p /etc/ld.so.conf.d
cat <<'CONF' | $SUDO tee /etc/ld.so.conf.d/glibc-env.conf >/dev/null
/usr/lib/x86_64-linux-gnu
/lib/x86_64-linux-gnu
/usr/lib64
/lib64
CONF
if [ ! -f /etc/ld.so.conf ]; then
    echo "include /etc/ld.so.conf.d/*.conf" | $SUDO tee /etc/ld.so.conf >/dev/null
fi
$SUDO "$SYS/usr/sbin/ldconfig"
echo "   /etc/ld.so.cache: $(file_size /etc/ld.so.cache) bytes"

echo "== 5. Locales (ru_RU.UTF-8, en_US.UTF-8) =="
for loc in ru_RU.UTF-8 en_US.UTF-8; do
    if [ ! -d "/usr/lib/locale/$loc" ]; then
        base=$(echo $loc | sed 's/\.UTF-8//')
        $SUDO "$SYS/usr/bin/localedef" -i "$base" -f UTF-8 "$loc" 2>/dev/null && echo "   $loc ready" \
            || echo "   $loc: error (non-fatal)"
    else
        echo "   $loc already exists"
    fi
done

echo "== 6. GDK-Pixbuf cache (GTK image loaders) =="
PXB=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0
if [ -d "$SYS$PXB/loaders" ] && [ ! -f "$SYS$PXB/loaders.cache" ]; then
    # paths in the cache must be SYSTEM ones (mounts already up from step 3)
    GDK_PIXBUF_MODULEDIR="$PXB/loaders" \
    "$SYS/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders" \
        "$PXB/loaders"/*.so > "$SYS$PXB/loaders.cache" 2>/dev/null || true
    [ -f "$SYS$PXB/loaders.cache" ] && echo "   loaders.cache created"
fi

echo "== 7. GSettings schemas (gschemas.compiled) =="
if [ -d "$SYS/usr/share/glib-2.0/schemas" ] && [ ! -f "$SYS/usr/share/glib-2.0/schemas/gschemas.compiled" ]; then
    "$SYS/usr/lib/x86_64-linux-gnu/glib-2.0/glib-compile-schemas" \
        "$SYS/usr/share/glib-2.0/schemas" 2>/dev/null && echo "   gschemas.compiled created"
fi

echo "== 8. Check: direct glibc binary launch (without glenv) =="
if [ ! -x "$SYS/usr/bin/hello" ]; then
    echo "   WARNING: hello not in sysroot (install the core group)"
    exit 1
elif "$SYS/usr/bin/hello"; then
    echo "   WORKS: glibc binary runs directly"
else
    echo "   WARNING: direct launch failed (check /lib64 loader + ld.so.cache)"
    exit 1
fi

echo "== 9. Compat: multiarch bin suffixes + SSL path =="
# Debian installs glxinfo.x86_64-linux-gnu etc. — provide plain names
for f in "$SYS"/usr/bin/*.x86_64-linux-gnu; do
    [ -e "$f" ] || break
    base="${f%.x86_64-linux-gnu}"
    [ -e "$base" ] || ln -s "$(basename "$f")" "$base"
done
# OpenSSL looks for /usr/lib/ssl/certs — point at host bundle (apk updates it)
[ -e "$SYS/usr/lib/ssl" ] || ln -s /etc/ssl "$SYS/usr/lib/ssl"
[ -e "$SYS/usr/lib/ssl/certs/ca-certificates.crt" ] && echo "   CA bundle visible" \
    || echo "   WARNING: no /etc/ssl/certs/ca-certificates.crt (apk add ca-certificates)"

echo "== 10. Wayland explicit-sync advertisement filter =="
# A GL stack without native fence fds (glenv Mesa on nouveau) must not let a
# client select linux-drm-syncobj explicit sync: it would wait for an acquire
# fence that can never exist and stall on black. The shim hides that one global
# announcement, so clients fall back to wl_buffer.release based implicit sync.
# musl never reads /etc/ld.so.preload, so this reaches glibc programs only.
PRELOAD_SO="$PREFIX/lib/glenv-wayland-filter.so"
if [ -f "$PRELOAD_SO" ]; then
    $SUDO sh -c "{ grep -vxF '$PRELOAD_SO' /etc/ld.so.preload 2>/dev/null; \
                   printf '%s\n' '$PRELOAD_SO'; } > /etc/ld.so.preload.new && \
                 chmod 644 /etc/ld.so.preload.new && \
                 mv -f /etc/ld.so.preload.new /etc/ld.so.preload"
    echo "   /etc/ld.so.preload -> $PRELOAD_SO"
else
    echo "   WARNING: $PRELOAD_SO is missing (shim not built)"
fi

echo "== Done =="
