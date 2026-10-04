# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-10-04

First public release.

### Added

- **glenv subsystem** — self-contained glibc (Debian trixie) prefix for any
  Alpine (musl, x86_64, OpenRC), routed at ELF level via PT_INTERP; glibc
  binaries run directly, no flags required.
- **`install.sh`** — one self-contained POSIX sh / BusyBox ash installer with
  nine stages: preflight, component menu, plan screen before sudo, privileges,
  downloads, glenv build, system integration, verify, done.
  - Arrow-key checkbox menu with presets `minimal / standard / full / custom`
    and live package counts and sizes; line mode when stdin is not a TTY;
    `--yes` and `--components=` for automation.
  - Plan screen lists every system change and is confirmed with `[y/N]`
    before any root action.
  - Byte-accurate progress bars (per package and overall, with speed/ETA),
    `.part` + rename, 30 s stall watchdog with `wget -c` resume.
  - **SHA256 verification of every `.deb`** against the Debian package index,
    for cached files as well as fresh downloads; mismatch forces a clean
    retry and the stage summary reports `sha256 verified`.
  - **`--uninstall` / `--purge`** — mirrored six-stage removal flow with its
    own plan screen: unmounts the binds, drops only glenv's `/etc/fstab`
    lines, removes the glibc loader (restoring a displaced `*.gcompat-shim`),
    cleans `ld.so.cache`, the preload filter line, `profile.d`, the symlink
    and empty mount-point dirs; verifies every removal; optional prefix
    deletion behind `--purge`.
  - Environment knobs: `GLENV_PREFIX`, `GLENV_MIRROR`, `GLENV_COMPONENTS`,
    `GLENV_TEST_SKIP_SYSTEM`.
- **Wayland explicit-sync filter** — `lib/glenv-wayland-filter.so` preloaded
  through `/etc/ld.so.preload`; rewrites
  `wp_linux_drm_syncobj_manager_v1` inside Wayland messages so glibc
  Chromium/Electron clients stop waiting for fences this GL stack cannot
  export (fixes permanently black windows).
- **PipeWire protocol modules** shipped in the sysroot — Wayland screen
  sharing (Discord, Electron) completes the handshake past the picker.
- **`glenv doctor`** — diagnostics for loader, cache, mounts, preload,
  PipeWire, TLS and desktop integration; `.desktop` installer for menu
  entries in KDE and other DEs/WMs.
- **`tools/`** — `integrate-system.sh` (idempotent entry-point repair),
  `fetch-deps.py` (extra Debian packages into the sysroot),
  `install.sh` compatibility wrapper.
- **Tests** — `tests/chroot-cleanroom.sh` (full install → verify → uninstall
  → purge cycle in a pristine Alpine chroot), `tests/menu-pty.py`
  (interactive menu through a pty), `tests/scan.sh` (syntax, English-only,
  no personal data).
- **CI** — GitHub Actions: static checks, pty menu test under BusyBox ash in
  an Alpine container, clean-room chroot test on the runner VM.
- **Docs** — README (quick start, uninstall, troubleshooting, structure),
  `docs/INSTALLER.md`, `docs/ARCHITECTURE.md`, `CONTRIBUTING.md`,
  `SECURITY.md`, GPL-3.0-only `LICENSE`.
