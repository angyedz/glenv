#!/bin/sh
# glenv setup — self-contained installer of the glibc subsystem on Alpine
# (musl, x86_64, OpenRC). One file, POSIX sh, BusyBox ash compatible:
# no python/go required to install; progress bars, component menu, plan screen.
#
#   sh install.sh
#   sh install.sh --help
#   sh install.sh --yes                       # non-interactive, default = full
#   sh install.sh --components=core,gl,net    # pick groups explicitly
#   echo "2" | sh install.sh                  # line menu when stdin is not a TTY
#   sh install.sh --uninstall                 # remove system integration (keep prefix)
#   sh install.sh --uninstall --purge         # ... and delete the prefix too
#
# Environment:
#   GLENV_PREFIX           install prefix (default /opt/glibc-env)
#   GLENV_MIRROR           Debian mirror (default https://deb.debian.org/debian)
#   GLENV_COMPONENTS       same as --components
#   GLENV_TEST_SKIP_SYSTEM internal test hook: stop before system changes
#
set -u

# ---------------------------------------------------------------- config ----
VERSION="1.0"
TREE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PREFIX="${GLENV_PREFIX:-/opt/glibc-env}"
MIRROR="${GLENV_MIRROR:-https://deb.debian.org/debian}"
DIST="trixie"
ARCH="amd64"
GROUPS="core gl x11 gui sound net fonts tools"
# bind-mount points owned by glenv (integration writes these to /etc/fstab)
MNTS="/usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib/locale /usr/share/i18n /usr/share/glvnd /usr/share/drirc.d"
N_STAGES=9
STAGE_N=0
STAGE_T0=0
YES=0
UNINSTALL=0
PURGE=0
SKIP_SYSTEM="${GLENV_TEST_SKIP_SYSTEM:-0}"

# ------------------------------------------------------------- terminal ----
esc=$(printf '\033')
CLEAR="${esc}[2J${esc}[H"
C_BOLD="" C_DIM="" C_GRN="" C_RED="" C_YEL="" C_CYN="" C_OFF=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    C_BOLD="${esc}[1m" C_DIM="${esc}[2m" C_GRN="${esc}[32m"
    C_RED="${esc}[31m" C_YEL="${esc}[33m" C_CYN="${esc}[36m" C_OFF="${esc}[0m"
fi
if printf '%s' "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" | grep -qi 'utf-\{0,1\}8'; then
    G_OK="✓" G_NO="✗" G_DOT="·" G_ARR="▸" G_F="█" G_E="░"
else
    G_OK="+" G_NO="x" G_DOT="." G_ARR=">" G_F="#" G_E="-"
fi

term_restore() {
    [ -t 1 ] && printf '%s[?25h' "$esc"
    if [ -n "${STTY_SAVED:-}" ] && [ -t 0 ]; then stty "$STTY_SAVED" 2>/dev/null || true; fi
    [ -n "${TMP:-}" ] && [ -d "${TMP:-}" ] && rm -rf "$TMP"
}
STTY_SAVED=""
TMP=""
trap 'term_restore' EXIT
trap 'printf "\n"; term_restore; exit 130' INT TERM
[ -t 1 ] && printf '%s[?25l' "$esc"

# --------------------------------------------------------------- output ----
now_cs() {
    if read -r _u _rest < /proc/uptime 2>/dev/null; then
        _w=${_u%%.*}
        if [ "$_w" = "$_u" ]; then printf '%s' "$((_w * 100))"
        else _f=${_u#*.}; printf '%s' "$((_w * 100 + 10#${_f:-0}))"; fi
    else
        printf '%s' "$(date +%s)00"
    fi
}
elap() { echo "$(( ($(now_cs) - STAGE_T0) / 10 ))"; }

stage() {
    STAGE_N=$((STAGE_N + 1)); STAGE_T0=$(now_cs)
    printf '\n%s  [%d/%d]%s %s%s%s\n' "$C_DIM" "$STAGE_N" "$N_STAGES" "$C_OFF" "$C_BOLD" "$1" "$C_OFF"
}
res() {   # res ok|same|skip|warn|fail "text"
    case "$1" in
        ok)   _c=$C_GRN; _g=$G_OK ;;
        same) _c=$C_DIM; _g=$G_DOT ;;
        skip) _c=$C_DIM; _g="–" ;;
        warn) _c=$C_YEL; _g=$G_NO ;;
        fail) _c=$C_RED; _g=$G_NO ;;
        *)    _c="";     _g=$G_DOT ;;
    esac
    printf '        %s%s%s %s\n' "$_c" "$_g" "$C_OFF" "$2"
}
inf() { printf '        %s%s%s %s\n' "$C_DIM" "$G_DOT" "$C_OFF" "$1"; }
head2() { printf '        %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
die() {
    printf '\n        %s%s failed:%s %s\n' "$C_RED" "$G_NO" "$C_OFF" "$1"
    printf '        %sfix it and re-run: sh install.sh%s\n' "$C_DIM" "$C_OFF"
    exit 1
}
hsize() {   # bytes -> human
    _b=$1
    if [ "$_b" -ge 1073741824 ]; then printf '%d.%d GB' "$((_b / 1073741824))" "$(( (_b % 1073741824) * 10 / 1073741824 ))"
    elif [ "$_b" -ge 1048576 ]; then printf '%d.%d MB' "$((_b / 1048576))" "$(( (_b % 1048576) * 10 / 1048576 ))"
    elif [ "$_b" -ge 1024 ]; then printf '%d KB' "$((_b / 1024))"
    else printf '%d B' "$_b"; fi
}
hkb() {     # kilobytes -> human
    _k=$1
    if [ "$_k" -ge 1048576 ]; then printf '%d.%d GB' "$((_k / 1048576))" "$(( (_k % 1048576) * 10 / 1048576 ))"
    else printf '%d.%d MB' "$((_k / 1024))" "$(( (_k % 1024) * 10 / 1024 ))"; fi
}
bar_str() { # cur total width -> "████░░░ 67%"
    _c=$1 _t=${2:-0} _w=${3:-24} _p=0
    if [ -n "$_t" ] && [ "$_t" -gt 0 ] 2>/dev/null; then
        _p=$((_c * 100 / _t)); [ "$_p" -gt 100 ] && _p=100
    fi
    _f=$((_p * _w / 100)) _i=0 _s=""
    while [ "$_i" -lt "$_w" ]; do
        if [ "$_i" -lt "$_f" ]; then _s="$_s$G_F"; else _s="$_s$G_E"; fi
        _i=$((_i + 1))
    done
    printf '%s %3d%%' "$_s" "$_p"
}
fmt_eta() { # centiseconds
    _s=$(($1 / 100))
    if [ "$_s" -le 0 ] 2>/dev/null; then printf -- '--'
    elif [ "$_s" -lt 60 ]; then printf '%ds' "$_s"
    else printf '%dm%02ds' "$((_s / 60))" "$((_s % 60))"; fi
}
fmt_speed() { # bytes per centisecond
    _v=$(($1 * 100 / 1048576))
    if [ "$_v" -ge 10 ]; then printf '%d MB/s' "$((_v / 10))"
    elif [ "$_v" -gt 0 ]; then printf '%d.%d MB/s' "$((_v / 10))" "$((_v % 10))"
    else _k=$(($1 * 100 / 1024)); printf '%d.%d KB/s' "$((_k / 10))" "$((_k % 10))"; fi
}

# ----------------------------------------------------------- components ----
c_title() {
    case "$1" in
        core)   printf 'glibc runtime (loader, ldconfig, locales, test binary)' ;;
        gl)     printf 'Mesa, EGL/GLES, Vulkan, VA-API (rendering)' ;;
        x11)    printf 'X11 client libraries' ;;
        gui)    printf 'GTK3 + zenity dialogs, icons, MIME data' ;;
        sound)  printf 'PipeWire + PulseAudio (audio, screen share)' ;;
        net)    printf 'TLS certificates, curl, NSS' ;;
        fonts)  printf 'DejaVu, Liberation UI fonts' ;;
        tools)  printf 'glxinfo/eglinfo, x11 test applications' ;;
        *)      printf '%s' "$1" ;;
    esac
}
c_pkgs() {
    case "$1" in
        core)   printf 'libc6 libc-bin locales hello' ;;
        gl)     printf 'libegl1 libegl-mesa0 libgl1 libglx0 libgles2 libopengl0 libglvnd0 libgbm1 libdrm2 mesa-va-drivers mesa-vulkan-drivers libvulkan1 libva2 libva-drm2 libva-x11-2 libva-wayland2' ;;
        x11)    printf 'libx11-6 libxcb1 libxext6 libxi6 libxtst6 libxss1 libxinerama1 libxcursor1 libsm6 libice6 libxt6 libxkbfile1 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxkbcommon0' ;;
        gui)    printf 'zenity libgtk-3-0t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 libcairo2 libpango-1.0-0 libglib2.0-0t64 gsettings-desktop-schemas shared-mime-info adwaita-icon-theme hicolor-icon-theme libsecret-1-0 libnotify4 libdbus-1-3 libexif12' ;;
        sound)  printf 'libpulse0 libpipewire-0.3-0t64 libpipewire-0.3-modules libspa-0.2-modules pipewire-bin pulseaudio-utils' ;;
        net)    printf 'curl ca-certificates openssl libnss3 libcups2t64' ;;
        fonts)  printf 'fonts-dejavu-core fonts-liberation2' ;;
        tools)  printf 'mesa-utils-bin x11-apps' ;;
    esac
}
sel_has()   { case " $SEL " in *" $1 "*) return 0 ;; esac; return 1; }
sel_add()   { sel_has "$1" || SEL="$SEL $1"; }
sel_del()   { _n=""; for _g in $SEL; do [ "$_g" = "$1" ] || _n="$_n $_g"; done; SEL=$_n; }
apply_preset() {
    case "$1" in
        min)  SEL="core" ;;
        std)  SEL="core gl x11 sound net fonts" ;;
        full) SEL="$GROUPS" ;;
        custom) : ;;
    esac
    sel_has core || SEL="core $SEL"
}

# ------------------------------------------------------- selection state ----
SEL="$GROUPS"
CUR=1
sel_stats() {  # sets CNT_g BY_g KB_g and SEL_CNT SEL_BYTES SEL_KB
    for _g in $GROUPS; do
        eval "_c=\${CNT_$_g:-0}; _b=\${BY_$_g:-0}; _k=\${KB_$_g:-0}"
        eval "CNT_$_g=\$_c; BY_$_g=\$_b; KB_$_g=\$_k"
    done
    SEL_CNT=0; SEL_BYTES=0; SEL_KB=0
    for _g in $GROUPS; do
        sel_has "$_g" || continue
        eval "SEL_CNT=\$((SEL_CNT + CNT_$_g)); SEL_BYTES=\$((SEL_BYTES + BY_$_g)); SEL_KB=\$((SEL_KB + KB_$_g))"
    done
}

# --------------------------------------------------------------- usage -----
usage() {
    cat <<EOF
glenv setup $VERSION — glibc subsystem installer for Alpine (musl)

usage: sh install.sh [options]

  --help                 this text
  --yes                  accept defaults (preset: full) and confirm everything
  --components=a,b,c     install only these groups: $GROUPS
  --uninstall            remove system integration (mounts, loader, PATH),
                          keep the installed prefix
  --uninstall --purge    ... and delete the prefix as well
  (no TTY on stdin)      type a line instead of the menu:
                         1|min, 2|std, 3|full, or group names: core,gl,net

every downloaded .deb is verified against the SHA256 from the Debian index

environment:
  GLENV_PREFIX=$PREFIX
  GLENV_MIRROR=$MIRROR

stages: preflight, components, plan, privileges, packages, glenv, system,
        verify, done
EOF
}

# ------------------------------------------------------------ preflight -----
fetch_index() {   # -> $PACKAGES (uncompressed) ; non-fatal on failure
    local url out age fsize
    url="$MIRROR/dists/$DIST/main/binary-$ARCH/Packages.xz"
    PACKAGES=""
    for f in "$PREFIX/debs/Packages" "$TREE/debs/Packages"; do
        [ -s "$f" ] || continue
        age=$(( ($(date +%s) - $(stat -c %Y "$f")) / 60 ))
        if [ "$age" -le 1440 ]; then PACKAGES=$f; inf "index: cached ($(stat -c %s "$f" | tr -d ' ') bytes, ${age}m old)"; break; fi
    done
    [ -n "$PACKAGES" ] && return 0

    out="$TMP/Packages.xz"
    inf "index: $url"
    wget -q -T 60 -O "$out" "$url" 2>/dev/null &
    _wp=$!
    _t0=$(now_cs); _pb=0; _sp=0; _lsize=-1; _lgrow=$_t0
    while kill -0 "$_wp" 2>/dev/null; do
        _b=$(stat -c %s "$out" 2>/dev/null || echo 0)
        _tn=$(now_cs); _dt=$((_tn - _t0))
        if [ "$_dt" -ge 1 ] && [ "$_b" -gt "$_pb" ]; then
            _sp=$((((_b - _pb)) * 100 / _dt)); _t0=$_tn; _pb=$_b
        fi
        if [ "$_b" -gt "$_lsize" ]; then
            _lsize=$_b; _lgrow=$_tn
        elif [ $((_tn - _lgrow)) -gt 4500 ]; then
            kill "$_wp" 2>/dev/null; break
        fi
        printf '\r        %sPackages.xz%s  %s  %s   \033[K' "$G_ARR" "$C_OFF" "$(hsize "$_b")" "$([ "$_sp" -gt 0 ] 2>/dev/null && fmt_speed "$_sp" || printf -- '--')"
        sleep 0.25
    done
    wait "$_wp" 2>/dev/null || true
    _b=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ "$_b" -lt 100000 ]; then
        printf '\r\033[K'
        res warn "index download failed (need network + CA certificates)"
        return 1
    fi
    if unxz -c "$out" > "$TMP/Packages" 2>/dev/null; then
        printf '\r        %sPackages.xz%s  %s  %s\n\033[K' "$G_ARR" "$C_OFF" "$(hsize "$_b")" "ok"
        PACKAGES=$TMP/Packages
        return 0
    fi
    printf '\r\033[K'
    res warn "index decompression failed"
    return 1
}

write_groups() {
    : > "$TMP/groups"
    for _g in $GROUPS; do
        printf 'G %s %s\n' "$_g" "$(c_pkgs "$_g")" >> "$TMP/groups"
    done
}

resolve_index() {  # $PACKAGES + $TMP/groups -> $STATS (P/S/M lines)
    STATS="$TMP/stats"
    awk -v SEL="$TMP/groups" '
    function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
    function stripver(s) { gsub(/\([^)]*\)/, "", s); return trim(s) }
    function flush(   i, n, a, p) {
        if (cur == "") return
        if ((arch == "amd64" || arch == "all") && !(cur in V)) {
            V[cur] = 1
            F[cur] = file; SZ[cur] = size + 0; ISZ[cur] = isize + 0; DEP[cur] = deps; SH[cur] = shasum
            n = split(prov, a, ",")
            for (i = 1; i <= n; i++) { p = stripver(a[i]); if (p != "" && !(p in PF)) PF[p] = cur }
        }
        cur = ""; file = ""; size = ""; isize = ""; deps = ""; prov = ""; arch = ""; ver = ""; shasum = ""
    }
    FILENAME != SEL {
        if ($0 == "") { flush(); next }
        if ($0 ~ /^[ \t]/) next
        pos = index($0, ":")
        if (pos == 0) next
        key = substr($0, 1, pos - 1); val = substr($0, pos + 2)
        if (key == "Package") { if (cur != "") flush(); cur = val }
        else if (key == "Version") ver = val
        else if (key == "Filename") file = val
        else if (key == "Size") size = val
        else if (key == "Installed-Size") isize = val
        else if (key == "Depends") deps = val
        else if (key == "Pre-Depends") deps = deps ", " val
        else if (key == "SHA256") shasum = val
        else if (key == "Provides") prov = val
        else if (key == "Architecture") arch = val
        next
    }
    FILENAME == SEL {
        if (substr($0, 1, 2) == "G ") {
            rest = substr($0, 3); sp = index(rest, " ")
            if (sp > 0) { GN[++gcnt] = substr(rest, 1, sp - 1); GP[substr(rest, 1, sp - 1)] = substr(rest, sp + 1) }
        }
        next
    }
    function qadd(nm) { if (nm in seen) return; seen[nm] = 1; Q[++ql] = nm }
    END {
        flush()
        for (gi = 1; gi <= gcnt; gi++) {
            g = GN[gi]
            for (k in Q) delete Q[k]
            hd = 0; ql = 0
            n = split(GP[g], a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "") qadd(a[i])
            cnt = 0; bytes = 0; disk = 0
            while (hd < ql) {
                hd++; nm = Q[hd]
                if (!(nm in V)) {
                    if (nm in PF) { if (!(PF[nm] in seen)) { seen[PF[nm]] = 1; Q[++ql] = PF[nm] } }
                    else missing[nm] = 1
                    continue
                }
                cnt++; bytes += SZ[nm]; disk += ISZ[nm]
                printf "P\t%s\t%s\t%s\t%d\t%d\t%s\n", g, nm, F[nm], SZ[nm], ISZ[nm], SH[nm]
                d = DEP[nm]
                if (d == "") continue
                ng = split(d, grps, ",")
                for (i = 1; i <= ng; i++) {
                    na = split(grps[i], alts, "|")
                    for (j = 1; j <= na; j++) {
                        alt = stripver(alts[j])
                        if (alt == "") continue
                        if ((alt in seen) || (alt in V) || (alt in PF)) { qadd(alt); break }
                    }
                }
            }
            printf "S\t%s\t%d\t%d\t%d\n", g, cnt, bytes, disk
        }
        for (m in missing) printf "M\t%s\n", m
    }
    ' "$PACKAGES" "$TMP/groups" > "$STATS" 2>"$TMP/awk.err"
    [ -s "$STATS" ] || { [ -s "$TMP/awk.err" ] && cat "$TMP/awk.err"; return 1; }
    return 0
}

load_stats() {
    tab=$(printf '\t')
    MISSING_N=0
    for _g in $GROUPS; do eval "CNT_$_g=0; BY_$_g=0; KB_$_g=0"; done
    [ -s "${STATS:-}" ] || return 0
    while IFS="$tab" read -r _t _g _a _b _c _d; do
        case "$_t" in
            S) eval "CNT_$_g=$_a; BY_$_g=$_b; KB_$_g=$_c" ;;
            M) MISSING_N=$((MISSING_N + 1)) ;;
        esac
    done < "$STATS"
}

build_list() {   # selected groups -> $LIST (name, file, size, kb, sha256)
    LIST="$TMP/list"
    : > "$LIST"
    tab=$(printf '\t')
    DL_TOTAL=0; N_PKG=0
    [ -s "${STATS:-}" ] || return 0
    while IFS="$tab" read -r _t _g _name _file _sz _kb _sha; do
        [ "$_t" = "P" ] || continue
        sel_has "$_g" || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$_name" "$_file" "$_sz" "$_kb" "$_sha" >> "$LIST"
    done < "$STATS"
    DL_TOTAL=$(awk -F'\t' '{s+=$3} END{print s+0}' "$LIST")
    N_PKG=$(wc -l < "$LIST" | tr -d ' ')
}

# ---------------------------------------------------------------- menu -----
read_key() {
    K=""
    if ! IFS= read -r -n 1 k1; then K="EOF"; return; fi
    case "$k1" in
        "$esc")
            if IFS= read -r -n 1 -t 1 k2 && [ "$k2" = "[" ]; then
                if IFS= read -r -n 1 -t 1 k3; then
                    case "$k3" in A) K=UP;; B) K=DOWN;; C) K=RIGHT;; D) K=LEFT;; *) K=ESC;; esac
                else K=ESC; fi
            else K=ESC; fi ;;
        "")  K=ENTER ;;
        " ") K=SPACE ;;
        *)   K=$k1 ;;
    esac
}

draw_menu() {
    sel_stats
    printf '%s' "$CLEAR"
    printf '  %sSelect components%s   %s(installed size / download shown live)%s\n\n' "$C_BOLD" "$C_OFF" "$C_DIM" "$C_OFF"
    printf '    %s1%s minimal  %s2%s standard  %s3%s full  %s4%s custom\n\n' \
        "$C_CYN" "$([ "$PRESET" = min ] && printf '>' || printf ' ')" \
        "$C_CYN" "$([ "$PRESET" = std ] && printf '>' || printf ' ')" \
        "$C_CYN" "$([ "$PRESET" = full ] && printf '>' || printf ' ')" \
        "$C_CYN" "$([ "$PRESET" = custom ] && printf '>' || printf ' ')"
    _i=0
    for _g in $GROUPS; do
        _i=$((_i + 1))
        if [ "$_i" -eq "$CUR" ]; then _mark="${C_BOLD}>${C_OFF}"; else _mark=" "; fi
        if sel_has "$_g"; then _x="[x]"; else _x="[ ]"; fi
        eval "_c=\$CNT_$_g; _b=\$BY_$_g; _k=\$KB_$_g"
        if [ "$_g" = core ]; then
            printf '   %s %s%s%s core%s  %-46s %2d pkgs · %7s · %8s\n' \
                "$_mark" "$C_GRN" "$_x" "$C_OFF" "$C_DIM" "(required) $(c_title core)" "$_c" "$(hsize "$_b")" "$(hkb "$_k")"
        else
            printf '   %s %s%s%s %-6s%s %-46s %2d pkgs · %7s · %8s\n' \
                "$_mark" "$C_DIM" "$_x" "$C_OFF" "$_g" "$C_OFF" "$(c_title "$_g")" "$_c" "$(hsize "$_b")" "$(hkb "$_k")"
        fi
    done
    printf '\n   %stotal: %d packages · %s download · %s on disk%s\n' "$C_BOLD" "$SEL_CNT" "$(hsize "$SEL_BYTES")" "$(hkb "$SEL_KB")" "$C_OFF"
    printf '   %sup/down%s move  %sspace%s toggle  %s1-4%s preset  %senter%s install\n' \
        "$C_CYN" "$C_OFF" "$C_CYN" "$C_OFF" "$C_CYN" "$C_OFF" "$C_CYN" "$C_OFF"
}

menu_loop() {
    PRESET=full
    STTY_SAVED=$(stty -g 2>/dev/null || true)
    [ -t 0 ] && stty -icanon -echo min 1 time 0 2>/dev/null || true
    while :; do
        draw_menu
        read_key
        case "$K" in
            UP)    [ "$CUR" -gt 1 ] && CUR=$((CUR - 1)) ;;
            DOWN)  [ "$CUR" -lt "$(echo $GROUPS | wc -w)" ] && CUR=$((CUR + 1)) ;;
            SPACE) _g=$(echo "$GROUPS" | cut -d' ' -f"$CUR")
                   if [ "$_g" = core ]; then :; elif sel_has "$_g"; then sel_del "$_g"; else sel_add "$_g"; fi
                   PRESET=custom ;;
            1) apply_preset min;  PRESET=min ;;
            2) apply_preset std;  PRESET=std ;;
            3) apply_preset full; PRESET=full ;;
            4) PRESET=custom ;;
            ENTER|EOF) break ;;
            QUIT) printf '%s' "$CLEAR"; die "aborted at component selection" ;;
        esac
    done
    [ -n "$STTY_SAVED" ] && stty "$STTY_SAVED" 2>/dev/null && STTY_SAVED=""
    [ -t 1 ] && printf '%s[?25h' "$esc"
    printf '%s' "$CLEAR"
}

line_menu() {   # stdin is not a TTY: read one line
    inf "no TTY — line mode (1=min 2=std 3=full | group names: core,gl,net)"
    IFS= read -r _line || _line=""
    case "$_line" in
        ""|3|full|all)  apply_preset full ;;
        1|min|minimal)  apply_preset min ;;
        2|std|standard) apply_preset std ;;
        *)
            _words=$(printf '%s' "$_line" | tr ',+' '  ')
            _ok=1; _any=0
            for _g in $_words; do
                _any=1
                case " $GROUPS " in *" $_g "*) ;; *) _ok=0 ;; esac
            done
            if [ "$_ok" = 1 ] && [ "$_any" = 1 ]; then
                SEL="core"
                for _g in $_words; do sel_add "$_g"; done
            else
                res warn "unknown answer '$_line', using full"; apply_preset full
            fi ;;
    esac
}

# --------------------------------------------------------------- plan ------
confirm() {
    if [ "$YES" = 1 ]; then inf "confirmed automatically (--yes)"; return 0; fi
    if [ -t 0 ]; then
        printf '  %s%s [y/N]%s ' "$C_BOLD" "${CONFIRM_Q:-proceed with installation?}" "$C_OFF"
        IFS= read -r -n 1 _a; printf '\n'
        case "$_a" in y|Y) return 0 ;; esac
        return 1
    fi
    printf '  %s%s [y/N]%s ' "$C_BOLD" "${CONFIRM_Q:-proceed with installation?}" "$C_OFF"
    IFS= read -r _a || _a=""
    case "$_a" in y|Y|yes|YES) return 0 ;; esac
    return 1
}

plan_screen() {
    # $1 = label, $2 = value (aligned two-column plan row)
    pl() { printf '        %s%-24s%s%s\n' "$C_DIM" "$1" "$C_OFF" "$2"; }
    apk_need
    pl "Alpine packages (apk)" " ${APK_NEED:-nothing}"
    if [ -n "${PACKAGES:-}" ]; then
        pl "Debian packages" " $SEL_CNT · $(hsize "$SEL_BYTES") download · $(hkb "$SEL_KB") on disk"
        for _g in $GROUPS; do
            sel_has "$_g" || continue
            eval "_c=\$CNT_$_g; _b=\$BY_$_g; _k=\$KB_$_g"
            [ "$_c" -gt 0 ] || continue
            printf '          %-6s %3d pkgs · %8s · %9s%s\n' "$_g" "$_c" "$(hsize "$_b")" "$(hkb "$_k")" \
                "$([ "$_g" = core ] && printf '  (required)')"
        done
    else
        pl "Debian packages" " index unavailable — exact numbers shown at download"
    fi
    pl "Disk required" " $(hkb "$SEL_KB") (+ $(hsize "${DL_TOTAL:-0}") packages cache)"
    pl "Prefix" " $PREFIX ($([ -d "$SYSROOT" ] && printf upgrade || printf fresh))"
    if [ "$FREE_KB" -gt 0 ]; then pl "Free space" " $(hsize "$((FREE_KB * 1024))")"; else pl "Free space" " unknown"; fi
    [ "${MISSING_N:-0}" -gt 0 ] && printf '        %sUnresolvable dependencies%s     %d (usually virtual packages — harmless)\n' "$C_YEL" "$C_OFF" "$MISSING_N"
    printf '\n        %sSystem changes (need root):%s\n' "$C_DIM" "$C_OFF"
    printf '          + /lib/ld-linux-x86-64.so.2        real glibc loader (gcompat kept as *.gcompat-shim)\n'
    printf '          + /lib64/ld-linux-x86-64.so.2      symlink (Debian binaries use this PT_INTERP)\n'
    printf '          + /etc/fstab                       %d bind mounts (persistent)\n' "7"
    printf '          + /etc/ld.so.conf.d/glibc-env.conf glibc library search paths\n'
    printf '          + /etc/ld.so.preload               Wayland explicit-sync filter\n'
    printf '          + /etc/profile.d/glibc-env.sh    PATH -> %s/bin\n' "$PREFIX"
    printf '          + /usr/local/bin/glenv             symlink\n'
    printf '          + mount --bind x7, ldconfig, localedef (ru_RU, en_US)\n'
    printf '          + apk add %s\n' "${APK_NEED:-nothing}"
    printf '        %sNothing is changed before you confirm.%s\n' "$C_DIM" "$C_OFF"
}

apk_need() {
    APK_NEED=""
    apk info -e bubblewrap >/dev/null 2>&1 || APK_NEED="bubblewrap"
    if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
        APK_NEED="$APK_NEED ca-certificates"
    fi
    APK_NEED=$(printf '%s' "$APK_NEED" | sed 's/^ *//')
}

# ----------------------------------------------------------- privileges ----
SUDO=""
setup_sudo() {
    if [ "$(id -u)" -eq 0 ]; then SUDO=""
    elif sudo -n true 2>/dev/null; then SUDO="sudo"
    else
        if [ -t 0 ]; then
            inf "administrator password required"
            sudo -v 2>/dev/null || die "sudo authentication failed"
            SUDO="sudo"
        elif [ -x "$HOME/.glenv/askpass.sh" ]; then
            SUDO_ASKPASS="$HOME/.glenv/askpass.sh"; export SUDO_ASKPASS
            sudo -A -v 2>/dev/null || die "sudo authentication failed (askpass)"
            SUDO="sudo -A"
        else
            die "need sudo: run interactively, or first run: glenv auth save"
        fi
    fi
}
as_root() { if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi; }

# ------------------------------------------------------------- download ----
verify_sha() {   # $1 = file, $2 = expected sha256 (empty or no tool = skip)
    [ -n "$2" ] || return 0
    command -v sha256sum >/dev/null 2>&1 || return 0
    [ "$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" = "$2" ]
}

download_all() {
    got=0; cached=0; failed=0; n=0; sha_ok=0
    GCUR=0; speed=0
    _gline() {
        printf '%s[%d/%d]%s %s  %s  %s  ETA %s' "$C_DIM" "$n" "$N_PKG" "$C_OFF" \
            "$(bar_str "$GCUR" "$DL_TOTAL" 26)" "$(hsize "$GCUR")" \
            "$([ "$speed" -gt 0 ] && fmt_speed "$speed" || printf -- '--')" \
            "$([ "$speed" -gt 0 ] && fmt_eta $(( (DL_TOTAL - GCUR) * 100 / speed )) || printf -- '--')"
    }
    draw() {  # $1 = live|final
        printf '\r        %s\033[K' "$(_gline)"
        if [ "$1" = final ]; then
            printf '\n\r        %s%s %s%s\033[K\n' "$G_ARR" "$_pkg" "$_pb" "$C_OFF"
        else
            printf '\n\r        %s%s %s%s\033[K\033[1A' "$G_ARR" "$_pkg" "$_pb" "$C_OFF"
        fi
    }
    while IFS="$tab" read -r _name _file _sz _kb _sha; do
        n=$((n + 1))
        _base=${_file##*/}
        _dest="$DEBS/$_base"
        if [ -s "$_dest" ]; then
            if verify_sha "$_dest" "$_sha"; then
                cached=$((cached + 1)); sha_ok=$((sha_ok + 1))
                got=$((got + _sz)); GCUR=$got; continue
            fi
            rm -f "$_dest"
            printf '\n'; inf "$_name: cached package failed sha256 — re-downloading"
        fi
        _pkg="$_name"
        _try=0
        while :; do
            _why=""
            [ -s "$_dest.part" ] || : > "$_dest.part"
            wget -q -T 60 -c -O "$_dest.part" "$MIRROR/$_file" 2>/dev/null &
            _wp=$!
            _stall=0; _lsize=-1; _lgrow=$(now_cs); speed=0
            t_prev=$(now_cs); b_prev=0
            while kill -0 "$_wp" 2>/dev/null; do
                _cur=$(stat -c %s "$_dest.part" 2>/dev/null || echo 0)
                GCUR=$((got + _cur))
                _tn=$(now_cs); _dt=$((_tn - t_prev))
                if [ "$_dt" -ge 1 ]; then
                    _db=$((_cur - b_prev)); [ "$_db" -lt 0 ] && _db=0
                    _inst=$((_db * 100 / _dt))
                    if [ "$_inst" -gt 0 ]; then
                        if [ "$speed" -eq 0 ]; then speed=$_inst; else speed=$(((speed * 7 + _inst * 3) / 10)); fi
                    else
                        speed=$(((speed * 7) / 10)); [ "$speed" -lt 1024 ] && speed=0
                    fi
                    t_prev=$_tn; b_prev=$_cur
                fi
                # watchdog: no growth for 30 s -> kill, resume on the next attempt
                if [ "$_cur" -gt "$_lsize" ]; then
                    _lsize=$_cur; _lgrow=$_tn
                elif [ $((_tn - _lgrow)) -gt 3000 ]; then
                    _stall=1; kill "$_wp" 2>/dev/null; break
                fi
                _pb="$(bar_str "$_cur" "$_sz" 24) $(hsize "$_cur")/$(hsize "$_sz")"
                draw live
                sleep 0.25
            done
            _rc=0; wait "$_wp" 2>/dev/null || _rc=$?
            [ "$_stall" = 1 ] && _rc=1
            if [ "$_rc" -eq 0 ] && ! verify_sha "$_dest.part" "$_sha"; then
                _rc=1; _why="sha256 mismatch"
                rm -f "$_dest.part"   # corrupt file: cannot resume, start over
            fi
            if [ "$_rc" -eq 0 ]; then
                mv -f "$_dest.part" "$_dest"
                sha_ok=$((sha_ok + 1))
                got=$((got + _sz)); GCUR=$got
                _pb="$(bar_str "$_sz" "$_sz" 24) $(hsize "$_sz")"
                draw final
                break
            fi
            _try=$((_try + 1))
            if [ "$_try" -ge 2 ]; then
                rm -f "$_dest.part"
                printf '\n'; failed=$((failed + 1))
                res warn "$_name: ${_why:-download failed} ($MIRROR/$_file)"
                break
            fi
            printf '\n'
            if [ -n "$_why" ]; then
                inf "$_name: $_why — re-downloading (attempt $((_try + 1))/2)"
            else
                inf "$_name: stalled, resuming (attempt $((_try + 1))/2)"
            fi
        done
    done < "$LIST"
    GCUR=$got
    [ "$cached" -gt 0 ] && inf "$cached of $N_PKG packages already cached"
    if [ "$failed" -gt 0 ]; then
        res warn "$failed of $N_PKG downloads failed"
        return 1
    fi
    if [ "$sha_ok" -gt 0 ] && [ "$sha_ok" -eq "$N_PKG" ]; then
        res ok "$N_PKG packages · $(hsize "$got") downloaded · sha256 verified"
    else
        res ok "$N_PKG packages · $(hsize "$got") downloaded"
    fi
    return 0
}

# ------------------------------------------------------------ extraction ---
extract_deb() {   # $1 = .deb, $2 = sysroot ; returns 0 ok
    _deb=$1; _out=$2; _off=8; _guard=0
    while [ "$_guard" -lt 16 ]; do
        _guard=$((_guard + 1))
        _hdr=$(tail -c +$((_off + 1)) "$_deb" 2>/dev/null | head -c 60)
        [ -n "$_hdr" ] || return 1
        _mname=$(printf '%s' "$_hdr" | cut -c1-16 | tr -d ' ')
        [ -n "$_mname" ] || return 1
        _msz=$(printf '%s' "$_hdr" | cut -c49-58 | tr -d ' ')
        case "$_msz" in ''|*[!0-9]*) return 1 ;; esac
        case "$_mname" in
            data.tar*|data.tar)
                _doff=$((_off + 60))
                tail -c +$((_doff + 1)) "$_deb" > "$TMP/member.bin" || return 1
                _fsize=$(stat -c %s "$_deb")
                if [ $((_doff + _msz + _msz % 2)) -ge "$_fsize" ]; then
                    _data="$TMP/member.bin"
                else
                    head -c "$_msz" "$TMP/member.bin" > "$TMP/data.bin" || return 1
                    _data="$TMP/data.bin"
                fi
                set -o pipefail
                case "$_mname" in
                    *.xz|*.lzma) unxz -c "$_data" | tar -x -C "$_out" ;;
                    *.gz|*.gzip) gzip -dc "$_data" | tar -x -C "$_out" ;;
                    data.tar)    tar -xf "$_data" -C "$_out" ;;
                    *) set +o pipefail; rm -f "$TMP/member.bin" "$TMP/data.bin"; return 2 ;;
                esac
                _rc=$?
                set +o pipefail
                rm -f "$TMP/member.bin" "$TMP/data.bin"
                return $_rc ;;
        esac
        _off=$((_off + 60 + _msz + _msz % 2))
    done
    return 1
}

extract_all() {
    n=0; ok=0; bad=0
    while IFS="$tab" read -r _name _file _sz _kb; do
        n=$((n + 1))
        _dest="$DEBS/${_file##*/}"
        if [ ! -s "$_dest" ]; then
            bad=$((bad + 1)); continue
        fi
        if extract_deb "$_dest" "$SYSROOT"; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1)); rm -f "$_dest"
            res warn "$_name: extraction failed (removed, will re-download)"
            continue
        fi
        printf '\r        %s[%d/%d] %s %s\033[K' "$C_DIM" "$n" "$N_PKG" "$G_ARR" "$_name"
    done < "$LIST"
    printf '\n'
    if [ "$bad" -gt 0 ]; then res warn "$ok of $N_PKG extracted, $bad failed"; return 1; fi
    res ok "$ok packages extracted · $(hkb "$SEL_KB") on disk"
    return 0
}

# ------------------------------------------------------------- glenv -------
build_glenv() {
    if [ -d "$TREE/src/glenv" ] && command -v go >/dev/null 2>&1; then
        (cd "$TREE/src/glenv" && go build -o "$PREFIX/bin/glenv" . 2>"$TMP/go.err") \
            && res ok "glenv built from source ($(hsize "$(stat -c %s "$PREFIX/bin/glenv")"))" \
            || { [ -s "$TMP/go.err" ] && head -5 "$TMP/go.err" | sed 's/^/          /';
                 [ -x "$TREE/bin/glenv" ] && cp "$TREE/bin/glenv" "$PREFIX/bin/glenv" \
                    && res ok "glenv: build failed, prebuilt binary used" \
                    || die "cannot build glenv and no prebuilt binary"; }
    elif [ -x "$TREE/bin/glenv" ]; then
        cp "$TREE/bin/glenv" "$PREFIX/bin/glenv"
        res ok "glenv: prebuilt binary ($(hsize "$(stat -c %s "$PREFIX/bin/glenv")"))"
    elif [ -x "$PREFIX/bin/glenv" ]; then
        res same "glenv: binary already present"
    else
        die "no glenv binary: copy the repository tree (bin/glenv) or install go"
    fi
    chmod 755 "$PREFIX/bin/glenv"

    mkdir -p "$PREFIX/lib"
    _shim="$PREFIX/lib/glenv-wayland-filter.so"
    if command -v gcc >/dev/null 2>&1 && [ -f "$TREE/src/shim/glenv-wayland-filter.c" ]; then
        if [ ! -f "$_shim" ] || [ "$TREE/src/shim/glenv-wayland-filter.c" -nt "$_shim" ]; then
            gcc -shared -fPIC -O2 -nostdlib -o "$_shim" "$TREE/src/shim/glenv-wayland-filter.c" 2>/dev/null \
                && res ok "Wayland filter shim compiled" \
                || res warn "shim compile failed — using shipped binary if present"
        fi
    fi
    if [ ! -f "$_shim" ] && [ -f "$TREE/lib/glenv-wayland-filter.so" ]; then
        cp "$TREE/lib/glenv-wayland-filter.so" "$_shim"
        res ok "Wayland filter shim copied from tree"
    fi
    [ -f "$_shim" ] && res ok "Wayland explicit-sync filter: $(hsize "$(stat -c %s "$_shim")")" \
                   || res warn "no shim: Wayland screen render fix disabled"
}

# -------------------------------------------------------- system changes ----
integrate_system() {
    SYS="$SYSROOT"
    _added=0
    for _d in $MNTS; do as_root mkdir -p "$_d" 2>/dev/null; done
    as_root mkdir -p /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib/locale 2>/dev/null

    # loader
    _ld="$SYS/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
    if [ -e /lib/ld-linux-x86-64.so.2 ] && ! cmp -s /lib/ld-linux-x86-64.so.2 "$_ld" 2>/dev/null; then
        if file_glibc_loader /lib/ld-linux-x86-64.so.2; then
            res same "/lib/ld-linux-x86-64.so.2 already our glibc loader"
        else
            [ -e /lib/ld-linux-x86-64.so.2.gcompat-shim ] || as_root mv /lib/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2.gcompat-shim
            as_root cp "$_ld" /lib/ld-linux-x86-64.so.2
            res ok "/lib/ld-linux-x86-64.so.2 <- sysroot (foreign shim kept as *.gcompat-shim)"
        fi
    elif [ ! -e /lib/ld-linux-x86-64.so.2 ]; then
        as_root cp "$_ld" /lib/ld-linux-x86-64.so.2 && res ok "/lib/ld-linux-x86-64.so.2 installed"
    else
        res same "/lib/ld-linux-x86-64.so.2 already ours"
    fi

    # Debian binaries carry PT_INTERP /lib64/ld-linux-x86-64.so.2 — without this
    # symlink every direct glibc exec fails with "not found" (rc=127)
    if [ -e /lib64/ld-linux-x86-64.so.2 ]; then
        res same "/lib64/ld-linux-x86-64.so.2"
    else
        [ -d /lib64 ] || [ -L /lib64 ] || as_root mkdir -p /lib64
        if as_root ln -sfn ../lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2; then
            res ok "/lib64/ld-linux-x86-64.so.2 -> ../lib/ld-linux-x86-64.so.2"
        else
            res fail "/lib64/ld-linux-x86-64.so.2 (direct glibc exec will not work)"
        fi
    fi

    # fstab mounts
    for _spec in \
        "$SYS/usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu" \
        "$SYS/usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu" \
        "$SYS/usr/lib64 /usr/lib64" \
        "$SYS/usr/lib/locale /usr/lib/locale" \
        "$SYS/usr/share/i18n /usr/share/i18n" \
        "$SYS/usr/share/glvnd /usr/share/glvnd" \
        "$SYS/usr/share/drirc.d /usr/share/drirc.d"; do
        _src=${_spec% *}; _dst=${_spec#* }
        grep -q " $_dst " /etc/fstab 2>/dev/null || \
            { echo "$_src $_dst none bind 0 0" | as_root tee -a /etc/fstab >/dev/null; _added=$((_added + 1)); }
    done
    if [ "$_added" -gt 0 ]; then res ok "/etc/fstab: +$_added bind mounts"; else res same "/etc/fstab: mounts already listed"; fi
    as_root mount -a 2>/dev/null || true
    _up=0
    for _d in $MNTS; do mount | grep -q " on $_d type" && _up=$((_up + 1)); done
    if [ "$_up" -eq "$(echo $MNTS | wc -w)" ]; then
        res ok "bind mounts active: $_up/7"
    else
        as_root sh -c 'mount -a 2>/dev/null'; _up=0
        for _d in $MNTS; do mount | grep -q " on $_d type" && _up=$((_up + 1)); done
        res warn "bind mounts active: $_up/7 (reboot may be needed)"
    fi

    # ld.so.conf + cache
    as_root mkdir -p /etc/ld.so.conf.d
    as_root tee /etc/ld.so.conf.d/glibc-env.conf >/dev/null <<'CONF'
/usr/lib/x86_64-linux-gnu
/lib/x86_64-linux-gnu
/usr/lib64
/lib64
CONF
    [ -f /etc/ld.so.conf ] || echo "include /etc/ld.so.conf.d/*.conf" | as_root tee /etc/ld.so.conf >/dev/null
    # must be the glibc ldconfig from the sysroot: busybox's `ldconfig` in PATH
    # exits 0 without writing a glibc cache
    _ldc="$SYS/usr/sbin/ldconfig"
    [ -x "$_ldc" ] || _ldc="$SYS/usr/bin/ldconfig"
    _ldc_ok=0
    if [ -x "$_ldc" ]; then as_root "$_ldc" >/dev/null 2>&1 && _ldc_ok=1; fi
    if [ "$_ldc_ok" != 1 ]; then as_root ldconfig >/dev/null 2>&1 || true; fi
    if [ -s /etc/ld.so.cache ]; then
        res ok "/etc/ld.so.cache rebuilt ($(stat -c %s /etc/ld.so.cache) bytes)"
    else
        res fail "/etc/ld.so.cache not written — glibc lookup will be slow/broken"
    fi

    # locales
    for _loc in ru_RU.UTF-8 en_US.UTF-8; do
        if [ -d "/usr/lib/locale/$_loc" ]; then res same "locale $_loc"; continue; fi
        _base=$(printf '%s' "$_loc" | sed 's/\.UTF-8//')
        if as_root "$SYS/usr/bin/localedef" -i "$_base" -f UTF-8 "$_loc" 2>/dev/null; then
            res ok "locale $_loc"
        else
            res warn "locale $_loc (non-fatal)"
        fi
    done

    # GDK-Pixbuf + GSettings (only when gui group selected)
    PXB=/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/2.10.0
    _q="$SYS/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders"
    if sel_has gui && [ -x "$_q" ] && [ -d "$SYS$PXB/loaders" ]; then
        if GDK_PIXBUF_MODULEDIR="$PXB/loaders" "$_q" "$PXB"/loaders/*.so \
                > "$TMP/loaders.cache" 2>/dev/null && [ -s "$TMP/loaders.cache" ]; then
            as_root cp "$TMP/loaders.cache" "$SYS$PXB/loaders.cache" 2>/dev/null \
                && res ok "gdk-pixbuf loaders.cache" \
                || res warn "gdk-pixbuf loaders.cache (cannot write)"
        else
            rm -f "$SYS$PXB/loaders.cache"
            res warn "gdk-pixbuf loaders.cache generation failed (non-fatal)"
        fi
    elif sel_has gui && [ ! -x "$_q" ]; then
        res warn "gdk-pixbuf-query-loaders not in sysroot (non-fatal)"
    elif sel_has gui; then
        res same "gdk-pixbuf loaders.cache"
    fi
    if sel_has gui && [ -d "$SYS/usr/share/glib-2.0/schemas" ] && [ ! -f "$SYS/usr/share/glib-2.0/schemas/gschemas.compiled" ]; then
        if "$SYS/usr/lib/x86_64-linux-gnu/glib-2.0/glib-compile-schemas" "$SYS/usr/share/glib-2.0/schemas" 2>/dev/null \
                && [ -s "$SYS/usr/share/glib-2.0/schemas/gschemas.compiled" ]; then
            res ok "glib gschemas.compiled"
        else
            rm -f "$SYS/usr/share/glib-2.0/schemas/gschemas.compiled"
            res warn "gschemas.compiled failed (non-fatal)"
        fi
    elif sel_has gui; then
        res same "glib gschemas.compiled"
    fi

    # multiarch bin suffixes + SSL path
    _ln=0
    for _f in "$SYS"/usr/bin/*.x86_64-linux-gnu; do
        [ -e "$_f" ] || break
        _b=${_f%.x86_64-linux-gnu}
        [ -e "$_b" ] || { ln -s "$(basename "$_f")" "$_b"; _ln=$((_ln + 1)); }
    done
    [ "$_ln" -gt 0 ] && res ok "binary name aliases: +$_ln" || res same "binary name aliases"
    if [ ! -e "$SYS/usr/lib/ssl" ]; then ln -s /etc/ssl "$SYS/usr/lib/ssl"; fi
    if [ -e "$SYS/usr/lib/ssl/certs/ca-certificates.crt" ]; then res ok "CA bundle visible via /usr/lib/ssl"
    else res warn "no CA bundle (apk add ca-certificates)"; fi

    # Wayland explicit-sync filter
    _pre="$PREFIX/lib/glenv-wayland-filter.so"
    if [ -f "$_pre" ]; then
        as_root sh -c "{ grep -vxF '$_pre' /etc/ld.so.preload 2>/dev/null; printf '%s\n' '$_pre'; } > /etc/ld.so.preload.new && chmod 644 /etc/ld.so.preload.new && mv -f /etc/ld.so.preload.new /etc/ld.so.preload"
        res ok "/etc/ld.so.preload -> Wayland filter (glibc only; musl ignores it)"
    else
        res warn "no shim: /etc/ld.so.preload untouched"
    fi

    # direct glibc launch proof
    if [ ! -x "$SYS/usr/bin/hello" ]; then
        res warn "test binary missing (core group?)"
    elif "$SYS/usr/bin/hello" >/dev/null 2>&1; then
        res ok "glibc binary runs directly: $SYS/usr/bin/hello"
    else
        res fail "glibc binary does not run (loader/ld.so.cache problem)"
    fi

    # PATH integration (system-wide)
    if as_root ln -sfn "$PREFIX/bin/glenv" /usr/local/bin/glenv 2>/dev/null; then
        res ok "/usr/local/bin/glenv -> $PREFIX/bin/glenv"
    elif as_root mkdir -p /usr/local/bin 2>/dev/null && as_root ln -sfn "$PREFIX/bin/glenv" /usr/local/bin/glenv 2>/dev/null; then
        res ok "/usr/local/bin/glenv -> $PREFIX/bin/glenv"
    else
        res warn "cannot create /usr/local/bin/glenv"
    fi

    as_root tee /etc/profile.d/glibc-env.sh >/dev/null <<EOF
# glenv glibc subsystem: bin in PATH, prefix auto-detected ($PREFIX)
case ":\$PATH:" in
  *:$PREFIX/bin:*) ;;
  *) export PATH="$PREFIX/bin:\$PATH" ;;
esac
EOF
    res ok "/etc/profile.d/glibc-env.sh"
}

file_glibc_loader() {   # is this file the real glibc loader (not the gcompat shim)?
    [ -r "$1" ] || return 1
    [ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -gt 100000 ] && return 0
    return 1
}

# -------------------------------------------------------------- verify -----
verify_all() {
    _p=0; _t=0
    chk() { _t=$((_t + 1)); if eval "$2" >/dev/null 2>&1; then _p=$((_p + 1)); res ok "$1"; else res fail "$1"; fi; }

    chk "glibc loader present"            "[ -e /lib/ld-linux-x86-64.so.2 ]"
    chk "ld.so.cache present"             "[ -s /etc/ld.so.cache ]"
    chk "sysroot libc present"            "[ -e $SYSROOT/usr/lib/x86_64-linux-gnu/libc.so.6 ]"
    chk "mount /usr/lib/x86_64-linux-gnu" "mount | grep -q ' on /usr/lib/x86_64-linux-gnu type'"
    chk "Wayland filter preloaded"        "grep -q glenv-wayland-filter /etc/ld.so.preload"
    if sel_has sound; then chk "PipeWire client modules" "[ -e $SYSROOT/usr/lib/x86_64-linux-gnu/pipewire-0.3/libpipewire-module-protocol-native.so ]"; fi
    if sel_has net; then chk "CA bundle" "[ -e /usr/lib/ssl/certs/ca-certificates.crt ] || [ -e /etc/ssl/certs/ca-certificates.crt ]"; fi
    chk "glibc binary runs directly"      "[ -x $SYSROOT/usr/bin/hello ] && $SYSROOT/usr/bin/hello"
    chk "glenv command available"         "[ -x $PREFIX/bin/glenv ]"

    printf '        %sown diagnostics (glenv doctor):%s\n' "$C_DIM" "$C_OFF"
    env HOME="$HOME" "$PREFIX/bin/glenv" doctor 2>&1 | sed 's/^/          /'

    if [ "$_p" -eq "$_t" ]; then res ok "$_p/$_t checks passed"; else res warn "$_p/$_t checks passed"; fi
    [ "$_p" -eq "$_t" ]
}

# ----------------------------------------------------------- uninstall ----
uninstall_plan() {
    _fn=$(grep -c "^$PREFIX/" /etc/fstab 2>/dev/null || true)
    case "$_fn" in ''|*[!0-9]*) _fn=0 ;; esac
    _mnt=0
    for _d in $MNTS; do
        if mount | grep -q " on $_d type"; then _mnt=$((_mnt + 1)); fi
    done
    printf '        %sSystem changes to undo (need root):%s\n' "$C_DIM" "$C_OFF"
    printf '          - %-32s %d line(s)\n' "/etc/fstab (glenv binds)" "$_fn"
    printf '          - %-32s %d/7 active\n' "bind mounts (unmount)" "$_mnt"
    _s="present"; [ -e /etc/ld.so.conf.d/glibc-env.conf ] || _s="absent"
    printf '          - %-32s %s\n' "/etc/ld.so.conf.d/glibc-env.conf" "$_s"
    _s="present"; [ -e /etc/ld.so.cache ] || _s="absent"
    printf '          - %-32s %s\n' "/etc/ld.so.cache" "$_s"
    _s="filter line"
    [ -f /etc/ld.so.preload ] || _s="file absent"
    if [ -f /etc/ld.so.preload ] && ! grep -q glenv-wayland-filter /etc/ld.so.preload 2>/dev/null; then
        _s="no glenv line"
    fi
    printf '          - %-32s %s\n' "/etc/ld.so.preload" "$_s"
    _s="present"; [ -e /etc/profile.d/glibc-env.sh ] || _s="absent"
    printf '          - %-32s %s\n' "/etc/profile.d/glibc-env.sh" "$_s"
    _s="symlink"
    [ -L /usr/local/bin/glenv ] || { [ -e /usr/local/bin/glenv ] && _s="not ours — kept" || _s="absent"; }
    printf '          - %-32s %s\n' "/usr/local/bin/glenv" "$_s"
    printf '          - %-32s %s\n' "/lib/ld-linux-x86-64.so.2" "remove loader, restore *.gcompat-shim"
    printf '          - %-32s %s\n' "/lib64/ld-linux-x86-64.so.2" "remove our symlink"
    printf '          - %-32s %s\n' "user glenv*.desktop entries" "removed"
    if [ "$PURGE" = 1 ]; then
        printf '          %s- %-32s DELETE (--purge)%s\n' "$C_YEL" "prefix $PREFIX" "$C_OFF"
    else
        printf '          - %-32s %s\n' "prefix $PREFIX" "kept (add --purge to delete)"
    fi
    printf '          - %-32s %s\n' "apk packages" "kept — harmless"
    printf '        %sNothing is changed before you confirm.%s\n' "$C_DIM" "$C_OFF"
}

uninstall_system() {
    # 1. unmount active binds
    _dn=0; _busy=0
    for _d in $MNTS; do
        if mount | grep -q " on $_d type"; then
            if as_root umount "$_d" 2>/dev/null || as_root umount -l "$_d" 2>/dev/null; then
                _dn=$((_dn + 1))
            else
                _busy=$((_busy + 1))
            fi
        fi
    done
    if [ "$_dn" -gt 0 ]; then
        res ok "bind mounts unmounted: $_dn"
    elif [ "$_busy" -gt 0 ]; then
        res warn "bind mounts busy: $_busy (reboot will release)"
    else
        res same "bind mounts: none active"
    fi

    # 2. drop glenv lines from /etc/fstab (literal prefix match)
    _fn=$(grep -c "^$PREFIX/" /etc/fstab 2>/dev/null || true)
    case "$_fn" in ''|*[!0-9]*) _fn=0 ;; esac
    if [ "$_fn" -gt 0 ]; then
        awk -v p="$PREFIX/" 'index($0, p) != 1' /etc/fstab > "$TMP/fstab.new" 2>/dev/null
        if as_root cp "$TMP/fstab.new" /etc/fstab; then
            res ok "/etc/fstab: removed $_fn glenv line(s)"
        else
            res fail "/etc/fstab: cannot rewrite"
        fi
    else
        res same "/etc/fstab: no glenv lines"
    fi

    # 3. ld.so.conf.d + ld.so.cache (musl ignores both)
    if [ -f /etc/ld.so.conf.d/glibc-env.conf ]; then
        as_root rm -f /etc/ld.so.conf.d/glibc-env.conf && res ok "/etc/ld.so.conf.d/glibc-env.conf removed"
    else
        res same "/etc/ld.so.conf.d/glibc-env.conf: absent"
    fi
    if [ -e /etc/ld.so.cache ]; then
        as_root rm -f /etc/ld.so.cache && res ok "/etc/ld.so.cache removed (glibc-only)"
    else
        res same "/etc/ld.so.cache: absent"
    fi

    # 4. ld.so.preload: remove only our line, keep foreign entries
    if [ -f /etc/ld.so.preload ] && grep -q glenv-wayland-filter /etc/ld.so.preload 2>/dev/null; then
        if as_root sh -c 'grep -v glenv-wayland-filter /etc/ld.so.preload > /etc/ld.so.preload.new 2>/dev/null; if [ -s /etc/ld.so.preload.new ]; then chmod 644 /etc/ld.so.preload.new; mv -f /etc/ld.so.preload.new /etc/ld.so.preload; else rm -f /etc/ld.so.preload.new /etc/ld.so.preload; fi'; then
            res ok "/etc/ld.so.preload: glenv filter line removed"
        else
            res fail "/etc/ld.so.preload: cannot rewrite"
        fi
    else
        res same "/etc/ld.so.preload: no glenv line"
    fi

    # 5. glibc loader: remove, restoring the gcompat shim we displaced
    _ldp=/lib/ld-linux-x86-64.so.2
    if [ -e "$_ldp" ] || [ -L "$_ldp" ]; then
        if file_glibc_loader "$_ldp"; then
            if [ -e "$_ldp.gcompat-shim" ]; then
                if as_root rm -f "$_ldp" && as_root mv "$_ldp.gcompat-shim" "$_ldp"; then
                    res ok "/lib/ld-linux-x86-64.so.2: gcompat shim restored"
                else
                    res fail "/lib/ld-linux-x86-64.so.2: cannot restore shim"
                fi
            else
                if as_root rm -f "$_ldp"; then
                    res ok "/lib/ld-linux-x86-64.so.2: glibc loader removed"
                else
                    res fail "/lib/ld-linux-x86-64.so.2: cannot remove"
                fi
            fi
        else
            res same "/lib/ld-linux-x86-64.so.2: not ours — untouched"
        fi
    else
        res same "/lib/ld-linux-x86-64.so.2: absent"
    fi

    # 6. /lib64 symlink (only if it is exactly the one we created)
    _p64=/lib64/ld-linux-x86-64.so.2
    if [ -L "$_p64" ] && [ "$(readlink "$_p64" 2>/dev/null)" = "../lib/ld-linux-x86-64.so.2" ]; then
        if as_root rm -f "$_p64"; then
            res ok "/lib64/ld-linux-x86-64.so.2: symlink removed"
            as_root rmdir /lib64 2>/dev/null || true
        else
            res fail "/lib64/ld-linux-x86-64.so.2: cannot remove"
        fi
    elif [ -e "$_p64" ]; then
        res same "/lib64/ld-linux-x86-64.so.2: not our symlink — untouched"
    else
        res same "/lib64/ld-linux-x86-64.so.2: absent"
    fi

    # 7. PATH integration
    if [ -L /usr/local/bin/glenv ]; then
        if as_root rm -f /usr/local/bin/glenv; then res ok "/usr/local/bin/glenv: removed"
        else res fail "/usr/local/bin/glenv: cannot remove"; fi
    elif [ -e /usr/local/bin/glenv ]; then
        res same "/usr/local/bin/glenv: not a symlink — untouched"
    else
        res same "/usr/local/bin/glenv: absent"
    fi
    if [ -f /etc/profile.d/glibc-env.sh ]; then
        if as_root rm -f /etc/profile.d/glibc-env.sh; then res ok "/etc/profile.d/glibc-env.sh removed"
        else res fail "/etc/profile.d/glibc-env.sh: cannot remove"; fi
    else
        res same "/etc/profile.d/glibc-env.sh: absent"
    fi

    # 8. mount-point dirs we created (only when empty)
    _rm=0
    for _d in $MNTS; do
        [ -d "$_d" ] || continue
        if as_root rmdir "$_d" 2>/dev/null; then _rm=$((_rm + 1)); fi
    done
    if [ "$_rm" -gt 0 ]; then res ok "empty mount-point dirs removed: $_rm"
    else res same "mount-point dirs: kept"; fi

    # 9. user desktop entries created by tools/glenv-desktop-install
    _dc=0
    for _f in "$HOME/.local/share/applications/"glenv*.desktop; do
        [ -e "$_f" ] || continue
        rm -f "$_f" && _dc=$((_dc + 1))
    done
    if [ "$_dc" -gt 0 ]; then res ok "user desktop entries removed: $_dc"
    else res same "user desktop entries: none"; fi

    # 10. optional purge
    if [ "$PURGE" = 1 ]; then
        case "$PREFIX" in
            ""|"/"|"/opt"|"/usr"|"/home"|"/var"|"/etc"|"/usr/local")
                res fail "refusing to delete '$PREFIX'" ;;
            *)
                if [ -d "$PREFIX" ]; then
                    _pk=$(du -sk "$PREFIX" 2>/dev/null | awk '{print $1}')
                    case "$_pk" in ''|*[!0-9]*) _pk=0 ;; esac
                    if as_root rm -rf "$PREFIX"; then
                        res ok "prefix deleted: $PREFIX ($(hkb "$_pk") freed)"
                    else
                        res fail "cannot delete $PREFIX"
                    fi
                else
                    res same "prefix already absent: $PREFIX"
                fi ;;
        esac
    else
        res same "prefix kept: $PREFIX (add --purge to delete)"
    fi
}

verify_uninstall() {
    _p=0; _t=0
    chk() { _t=$((_t + 1)); if eval "$2" >/dev/null 2>&1; then _p=$((_p + 1)); res ok "$1"; else res fail "$1"; fi; }

    chk "no glenv fstab lines"            "! grep -q \"^$PREFIX/\" /etc/fstab"
    chk "no x86_64-linux-gnu bind mounts" "! mount | grep -q ' on /usr/lib/x86_64-linux-gnu type'"
    chk "no glenv line in ld.so.preload"  "! grep -q glenv-wayland-filter /etc/ld.so.preload"
    chk "no ld.so.conf.d/glibc-env.conf"  "[ ! -e /etc/ld.so.conf.d/glibc-env.conf ]"
    chk "no glibc ld.so.cache"            "[ ! -e /etc/ld.so.cache ]"
    chk "no /etc/profile.d/glibc-env.sh"  "[ ! -e /etc/profile.d/glibc-env.sh ]"
    chk "no /usr/local/bin/glenv"         "[ ! -e /usr/local/bin/glenv ]"
    chk "glibc loader gone or not ours"   "! file_glibc_loader /lib/ld-linux-x86-64.so.2"
    [ "$PURGE" = 1 ] && chk "prefix deleted" "[ ! -d $PREFIX ]"

    if [ "$_p" -eq "$_t" ]; then res ok "$_p/$_t checks passed"; else res warn "$_p/$_t checks passed"; fi
    [ "$_p" -eq "$_t" ]
}

uninstall_flow() {
    N_STAGES=6
    CONFIRM_Q="proceed with removal?"

    # ---- 1. preflight (light: no index, no network, no components)
    stage "Preflight"
    [ "$(uname -m)" = "x86_64" ] && res ok "architecture x86_64" || res warn "not x86_64"
    command -v sudo >/dev/null 2>&1 || [ "$(id -u)" -eq 0 ] || die "need sudo (or run as root)"
    if [ -d "$PREFIX" ]; then
        _pk=$(du -sk "$PREFIX" 2>/dev/null | awk '{print $1}')
        case "$_pk" in ''|*[!0-9]*) _pk=0 ;; esac
        res ok "prefix $PREFIX ($(hkb "$_pk"))"
    else
        res warn "prefix $PREFIX absent — cleaning system leftovers only"
    fi
    inf "removal only: no downloads, no apk changes"

    # ---- 2. plan
    stage "Plan"
    uninstall_plan
    if ! confirm; then
        printf '  %scancelled — nothing was changed%s\n\n' "$C_YEL" "$C_OFF"
        exit 0
    fi
    res ok "confirmed"

    # ---- 3. privileges
    stage "Privileges"
    setup_sudo
    [ -n "$SUDO" ] && res ok "root access granted ($SUDO)" || res ok "running as root"

    # ---- 4. remove
    stage "Remove"
    uninstall_system

    # ---- 5. verify
    stage "Verify"
    verify_uninstall || true

    # ---- 6. done
    stage "Done"
    res ok "system integration removed"
    if [ "$PURGE" = 1 ]; then
        res ok "prefix deleted"
    else
        res same "prefix kept at $PREFIX"
    fi
    printf '\n        %snext steps:%s\n' "$C_DIM" "$C_OFF"
    printf '          re-run installer:  sh %s\n' "$0"
    if [ "$PURGE" != 1 ]; then
        printf '          restore PATH:      ln -s %s/bin/glenv /usr/local/bin/glenv\n' "$PREFIX"
    fi
    printf '\n  %suninstall finished%s\n\n' "$C_GRN" "$C_OFF"
}

# ---------------------------------------------------------------- main -----
main() {
    COMPONENTS_SET=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --yes|-y)  YES=1 ;;
            --components=*) SEL=$(printf '%s' "${1#--components=}" | tr ',+' '  '); COMPONENTS_SET=1 ;;
            --uninstall) UNINSTALL=1 ;;
            --purge)     PURGE=1 ;;
            *) printf 'unknown option: %s\n' "$1"; usage; exit 2 ;;
        esac
        shift
    done
    if [ "$PURGE" = 1 ] && [ "$UNINSTALL" != 1 ]; then
        die "--purge only makes sense together with --uninstall"
    fi
    if [ -n "${GLENV_COMPONENTS:-}" ]; then
        SEL=$(printf '%s' "$GLENV_COMPONENTS" | tr ',+' '  ')
        COMPONENTS_SET=1
    fi

    SYSROOT="$PREFIX/sysroot"
    DEBS="$PREFIX/debs"
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/glenv-setup.XXXXXX") || die "cannot create temp dir"

    printf '\n  %sglenv setup %s%s — glibc subsystem for Alpine (musl, x86_64)\n' "$C_BOLD" "$VERSION" "$C_OFF"
    printf '  %s%s%s\n' "$C_DIM" "----------------------------------------------" "$C_OFF"

    if [ "$UNINSTALL" = 1 ]; then
        uninstall_flow
        return
    fi

    # ---- 1. preflight
    stage "Preflight"
    [ -f /etc/alpine-release ] && res ok "Alpine $(cat /etc/alpine-release)" || res warn "not Alpine (continuing anyway)"
    [ "$(uname -m)" = "x86_64" ] && res ok "architecture x86_64" || die "need x86_64 (glibc subsystem is amd64)"
    command -v wget  >/dev/null 2>&1 && res ok "wget (busybox)" || die "need wget"
    command -v awk   >/dev/null 2>&1 && res ok "awk" || die "need awk"
    command -v tar   >/dev/null 2>&1 && res ok "tar" || die "need tar"
    command -v sha256sum >/dev/null 2>&1 && res ok "sha256sum (busybox)" || res warn "sha256sum missing — package hashes will not be verified"
    command -v unxz  >/dev/null 2>&1 || res warn "unxz missing — .deb extraction will fail"
    command -v sudo  >/dev/null 2>&1 || [ "$(id -u)" -eq 0 ] || die "need sudo (or run as root)"
    command -v rc-update >/dev/null 2>&1 || res warn "OpenRC not found (integration step skipped?)"
    _ddir=$(dirname "$PREFIX"); [ -d "$_ddir" ] || _ddir=/
    FREE_KB=$(df -Pk "$_ddir" 2>/dev/null | awk 'NR==2{print $4}')
    case "$FREE_KB" in ''|*[!0-9]*) FREE_KB=0 ;; esac
    if [ "$FREE_KB" -gt 0 ]; then inf "prefix $PREFIX · free $(hsize "$((FREE_KB * 1024))")"; else inf "prefix $PREFIX · free space unknown"; fi
    fetch_index || true
    if [ -n "${PACKAGES:-}" ] && [ -f "$PACKAGES" ]; then
        write_groups
        if resolve_index; then
            load_stats
            res ok "index resolved: $(grep -c '^P' "$STATS" 2>/dev/null || echo 0) packages, $(grep -c '^S' "$STATS") groups"
        else
            res warn "dependency resolution failed — sizes unavailable"
        fi
    else
        write_groups
    fi
    [ "${MISSING_N:-0}" -gt 0 ] && inf "$MISSING_N unresolvable dependencies (virtual packages)"

    # ---- 2. components
    stage "Components"
    if [ "$COMPONENTS_SET" = 1 ] || [ "$YES" = 1 ]; then
        if [ "$COMPONENTS_SET" = 1 ]; then
            apply_preset custom   # keeps --components selection (core forced in)
        else
            apply_preset full
        fi
        sel_stats
        res ok "selected (non-interactive): $SEL"
    elif [ -t 0 ]; then
        menu_loop
        sel_stats
        res ok "selected: $SEL"
    else
        line_menu
        sel_stats
        res ok "selected: $SEL"
    fi
    if [ -z "${PACKAGES:-}" ]; then
        inf "no package index yet — attempting download before the plan"
        fetch_index || true
        if [ -n "${PACKAGES:-}" ]; then write_groups; resolve_index && load_stats; fi
    fi
    sel_stats
    build_list

    # ---- 3. plan
    stage "Plan"
    plan_screen
    if ! confirm; then
        printf '  %scancelled — nothing was changed%s\n\n' "$C_YEL" "$C_OFF"
        exit 0
    fi
    res ok "confirmed"

    # ---- 4. privileges
    stage "Privileges"
    setup_sudo
    [ -n "$SUDO" ] && res ok "root access granted ($SUDO)" || res ok "running as root"
    if [ ! -d "$PREFIX" ]; then
        as_root mkdir -p "$PREFIX" && as_root chown "$(id -un)" "$PREFIX"
    fi
    mkdir -p "$DEBS" "$SYSROOT" "$PREFIX/bin" "$PREFIX/lib"
    apk_need
    if [ -n "$APK_NEED" ]; then
        inf "apk add $APK_NEED"
        if as_root apk add --no-cache $APK_NEED >/dev/null 2>&1; then
            res ok "apk packages installed: $APK_NEED"
        else
            res warn "apk add failed (offline?) — some features may be missing"
        fi
    else
        res same "apk: nothing to install"
    fi
    # keep the index inside the prefix for later runs
    if [ -n "${PACKAGES:-}" ] && [ "$PACKAGES" != "$DEBS/Packages" ] && [ -f "$PACKAGES" ]; then
        cp "$PACKAGES" "$DEBS/Packages" 2>/dev/null && PACKAGES="$DEBS/Packages"
    fi

    # ---- 5. packages
    stage "Packages"
    tab=$(printf '\t')
    [ -s "$LIST" ] || { [ -n "${PACKAGES:-}" ] && write_groups && resolve_index && load_stats && build_list; }
    [ -s "$LIST" ] || die "empty package list (no index / network?)"
    download_all || die "downloads failed"
    extract_all  || die "extraction failed"
    # multiarch helper names (glxinfo.x86_64-linux-gnu -> glxinfo) etc. handled in system stage

    # ---- 6. glenv
    stage "glenv"
    build_glenv

    # ---- 7. system
    stage "System integration"
    if [ "$SKIP_SYSTEM" = "1" ]; then
        res skip "GLENV_TEST_SKIP_SYSTEM=1 — system changes skipped (test mode)"
    else
        integrate_system
    fi

    # ---- 8. verify
    stage "Verify"
    if [ "$SKIP_SYSTEM" = "1" ]; then
        res skip "skipped in test mode (system untouched)"
    else
        verify_all || true
    fi

    # ---- 9. done
    stage "Done"
    res ok "prefix       $PREFIX"
    res ok "packages     $N_PKG · $(hsize "${DL_TOTAL:-0}") · $(hkb "$SEL_KB") installed"
    res ok "groups       $SEL"
    printf '\n        %snext steps:%s\n' "$C_DIM" "$C_OFF"
    printf '          glenv doctor            # subsystem health\n'
    printf '          glenv run --sandbox=full <program>\n'
    printf '          sh %s --help            # options\n' "$0"
    printf '\n  %sinstallation finished%s\n\n' "$C_GRN" "$C_OFF"
}

main "$@"
