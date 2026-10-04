# glenv installer reference

`install.sh` is a single self-contained POSIX sh script, compatible with
BusyBox ash — installing needs no Python, Go or compiler on the target
machine. The supported target is Alpine 3.x / musl / x86_64; other
architectures and non-Alpine hosts are rejected. OpenRC is tested; other init
systems need an administrator-configured boot-time `mount -a`. Everything it
will do is shown on the plan screen **before** the first `sudo`.

## Usage

```sh
sh install.sh                       # interactive menu
sh install.sh --yes                 # non-interactive, preset: full
sh install.sh --components=core,gl,net
echo "2" | sh install.sh            # line mode when stdin is not a TTY
sh install.sh --uninstall           # remove integration, keep prefix
sh install.sh --uninstall --purge   # ... and delete the prefix
```

## Flags

| Flag | Meaning |
|---|---|
| `--help`, `-h` | print usage and exit |
| `--yes`, `-y` | accept defaults (preset `full`) and confirm every prompt |
| `--components=a,b,c` | install only these groups (see below) |
| `--uninstall` | system-removal flow: unmount, fstab, loader, caches, symlink |
| `--uninstall --purge` | the same, then delete `$GLENV_PREFIX` as well |
| `--purge` alone | rejected — it only makes sense with `--uninstall` |

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `GLENV_PREFIX` | `/opt/glibc-env` | install prefix (sysroot, debs, tools) |
| `GLENV_MIRROR` | `https://deb.debian.org/debian` | Debian mirror (suite `trixie`, `amd64`) |
| `GLENV_DIST` | `trixie` | Debian suite for the glibc userspace |
| `GLENV_DEBIAN_ARCH` | `amd64` | Debian package architecture (this build supports `amd64` only) |
| `GLENV_COMPONENTS` | — | same as `--components` (flag wins) |
| `GLENV_TEST_SKIP_SYSTEM` | `0` | internal test hook: stop before system changes |
| `GLENV_TEST_ALLOW_HOST` | `0` | internal test hook used only by the pty test; bypasses Alpine/musl/apk preflight checks |

`GLENV_PREFIX` must be a dedicated absolute directory path using only letters,
digits, `/`, `.`, `_` and `-`; system-root paths, `..` components and whitespace
are rejected.

## Components (mutually exclusive groups)

| Group | Contents |
|---|---|
| `core` | glibc runtime, busybox-free base tools, `hello` test binary |
| `gl` | Mesa/GL/EGL stack, glvnd |
| `x11` | X11 client libraries, xauth |
| `gui` | GTK3/4, gdk-pixbuf loaders, GLib schemas |
| `sound` | PipeWire client + protocol modules, pulse audio utils |
| `net` | curl, CA certificates, OpenSSL |
| `fonts` | DejaVu + fontconfig cache |
| `tools` | man-db, less, extra CLI utilities |

Presets:

| Preset | Groups |
|---|---|
| `1 minimal` | `core` |
| `2 standard` | `core gl x11 sound net fonts` |
| `3 full` | everything (default for `--yes`) |
| `4 custom` | whatever the checkboxes say |

Line mode (stdin is not a TTY) accepts `1|min`, `2|std`, `3|full`, a list of
group names (`core,gl,net`), or empty = full.

## The nine stages

| # | Stage | What happens | Root? |
|---|---|---|---|
| 1 | Preflight | host report (musl, loader, DE, GPU), tool check, package index fetch, dependency resolution, ASCII progress bars preview | no |
| 2 | Components | arrow-key menu with live sizes, or line/flag input | no |
| 3 | Plan | exact list of system changes + package counts/sizes/disk, `[y/N]` | no |
| 4 | Privileges | one sudo authentication (askpass helper saved), apk dependencies | yes |
| 5 | Packages | per-package byte bar + overall bar (speed/ETA), `.part`+rename, 30 s stall watchdog with resume, **SHA256 verification** of every `.deb` | no |
| 6 | glenv | builds the router and the Wayland filter when a toolchain exists, otherwise copies the prebuilts | no |
| 7 | System | loader + `/lib64` symlink, bind mounts + `/etc/fstab`, `ldconfig`, locales, gdk-pixbuf/glib caches, SSL path, preload filter, profile.d, symlink | yes |
| 8 | Verify | health checks + `glenv doctor` | — |
| 9 | Done | summary (prefix, packages, groups, next steps) | — |

The uninstall flow uses six stages of its own
(`Preflight → Plan → Privileges → Remove → Verify → Done`) and does not
touch the network at all.
Purge is guarded by a `.glenv-prefix` ownership marker. Existing installations
created by earlier versions without that marker can be uninstalled normally,
but the prefix is deliberately retained.

## Download verification

For every package the resolver extracts `SHA256` from the Debian `Packages`
index (the same field `apt` checks). A file — freshly downloaded **or already
cached** — is only accepted when `sha256sum` matches:

* cached mismatch → file deleted and re-downloaded;
* fresh mismatch → `.part` deleted (a corrupt file cannot be resumed) and the
  download retried once from scratch;
* the stage summary reports `sha256 verified` when every package passed.

If `sha256sum` is missing (it normally is not — BusyBox ships it) the
preflight warns and verification is skipped rather than blocking the install.

## Idempotency

Every stage is safe to re-run: mounts are already mounts, files already
present report `·` (same) instead of `✓` (changed), caches are regenerated
only when missing, and upgrades over an existing prefix complete in all nine
stages with no manual cleanup.
