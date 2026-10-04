#!/bin/sh
# Static checks for the glenv repo: shell/python syntax, English-only sources,
# no personal data. Run from anywhere:  sh tests/scan.sh
set -u

TREE=$(cd "$(dirname "$0")/.." && pwd)
cd "$TREE" || exit 1
FAILS=0
ok() { printf '[scan] ok:   %s\n' "$1"; }
no() { printf '[scan] FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

FILES=$(find . -type f \
        \( -name '*.sh' -o -name '*.py' -o -name '*.go' -o -name '*.c' \
           -o -name '*.md' -o -name 'LICENSE' -o -name '*.yml' -o -name '*.desktop' \) \
        ! -path './sysroot/*' ! -path './debs/*' ! -path './.git/*' ! -path './tests/__pycache__/*' \
        | sort)
[ -n "$FILES" ] || { echo "[scan] no source files found"; exit 1; }

# 1. shell syntax
for f in $FILES; do
    case "$f" in
        *.sh)
            if sh -n "$f" 2>/dev/null; then ok "sh -n ${f#./}"; else no "sh -n ${f#./}"; fi
            if command -v bash >/dev/null 2>&1; then
                if bash -n "$f" 2>/dev/null; then ok "bash -n ${f#./}"; else no "bash -n ${f#./}"; fi
            fi
            ;;
    esac
done

# 2. python syntax
if command -v python3 >/dev/null 2>&1; then
    for f in $FILES; do
        case "$f" in
            *.py)
                if python3 -m py_compile "$f" 2>/dev/null; then ok "py_compile ${f#./}"; else no "py_compile ${f#./}"; fi
                ;;
        esac
    done
else
    echo "[scan] skip: python3 not available"
fi

# 3. Go sources compile (only if a toolchain is present)
if command -v go >/dev/null 2>&1 && [ -f src/glenv/go.mod ]; then
    if (cd src/glenv && go build -o /dev/null . >/dev/null 2>&1); then
        ok "go build src/glenv"
    else
        no "go build src/glenv"
    fi
fi

# 4. Wayland shim compiles (only if a compiler is present)
if command -v gcc >/dev/null 2>&1; then
    _out=$(mktemp)
    if gcc -shared -fPIC -O2 -nostdlib -o "$_out" src/shim/glenv-wayland-filter.c 2>/dev/null; then
        ok "gcc shim build"
    else
        no "gcc shim build"
    fi
    rm -f "$_out"
fi

# 5. English-only: no Cyrillic in sources
if command -v python3 >/dev/null 2>&1; then
    if printf '%s\n' "$FILES" | python3 -c '
import re, sys
pat = re.compile(r"[\u0400-\u04FF]")
bad = []
for path in (l.strip() for l in sys.stdin):
    if not path:
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        continue
    for i, line in enumerate(text.splitlines(), 1):
        if pat.search(line):
            bad.append(f"{path}:{i}: {line.strip()[:70]}")
if bad:
    print("\n".join(bad[:20]))
    sys.exit(1)
'; then
        ok "no Cyrillic in sources (English-only)"
    else
        no "Cyrillic found in sources (must be English-only)"
    fi
else
    echo "[scan] skip: python3 not available (Cyrillic scan)"
fi

# 6. no personal data / secrets (skip this file itself: it holds the pattern)
SECRETS=$(printf '%s\n' "$FILES" | grep -v 'tests/scan\.sh$' \
          | xargs grep -InE '8861|romsez870|gmail\.com|/home/angyedz' 2>/dev/null || true)
if [ -z "$SECRETS" ]; then
    ok "no personal data in sources"
else
    no "personal data found in sources:"
    printf '%s\n' "$SECRETS" | sed 's/^/        /'
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "[scan] ALL PASSED"
    exit 0
else
    echo "[scan] $FAILS FAILURE(S)"
    exit 1
fi
