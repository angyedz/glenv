#!/bin/sh
# Compatibility wrapper: the self-contained installer lives at the prefix root.
# Kept so existing commands keep working:
#     sh /opt/glibc-env/tools/install.sh
# See install.sh --help for options (presets, plan screen, component menu).
exec sh "$(cd "$(dirname "$0")/.." && pwd)/install.sh" "$@"
