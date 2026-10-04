# Contributing to glenv

Thanks for your interest in improving glenv.

## Ground rules

- **English only** — code, comments, commit messages, docs and the installer
  UI. `tests/scan.sh` enforces this (no Cyrillic in sources).
- **GPL-3.0-only** — by contributing you agree your changes are released
  under the same license (see `LICENSE`).
- **No personal data** in the repository — no home paths, e-mails, passwords,
  hostnames. `tests/scan.sh` checks for known leftovers.
- **No workarounds inside applications.** Fixes belong in glenv itself
  (loader, integration, preload filter, sysroot contents). Diagnostic flags
  are fine for root-causing but must not ship enabled.

## Development setup

```sh
git clone https://github.com/angyedz/glenv.git
cd glenv
```

The installer itself needs only POSIX sh; for development you additionally
want `python3` (tests, fetch-deps), `go` (router) and `gcc` (wayland shim).

## Making changes

1. Create a branch: `git checkout -b feature/short-name`.
2. Implement the change. Keep `install.sh` self-contained and BusyBox
   ash-compatible: no bashisms beyond what BusyBox ash supports, no
   Python/Go on the install path.
3. If you touch system integration, update **both** `install.sh` (stage 7)
   and `tools/integrate-system.sh` — they must stay in sync.
4. If you touch the removal logic, keep the `--uninstall` flow mirroring
   the install flow, and update the tables in `README.md` /
   `docs/ARCHITECTURE.md`.
5. Run the local gates:

   ```sh
   sh tests/scan.sh              # syntax + scans (no root)
   python3 tests/menu-pty.py     # interactive menu (no root)
   sh tests/chroot-cleanroom.sh   # full install/uninstall cycle (sudo)
   ```

6. Commit with a clear message (what + why, imperative mood).

## Pull requests

- Describe the problem and the approach; link issues.
- Keep PRs focused — one concern per PR.
- All three CI jobs must be green (static, pty menu, clean-room).
- For UI changes, a short screen recording or screenshot in the PR helps.

## Reporting bugs

Use GitHub issues. Include: Alpine version (`cat /etc/alpine-release`),
`uname -m`, glenv install mode (preset/components), desktop and session type
(Wayland/X11), the exact command, expected vs actual output, and the tail of
the installer log if relevant. See `SECURITY.md` for security reports —
those go privately, not into public issues.
