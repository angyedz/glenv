# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use
GitHub's private reporting on this repository
(*Security → Report a vulnerability*), or contact the maintainer directly
via the e-mail in the git history of the repository.

Include:

- affected component (`install.sh`, router, wayland filter, integration);
- a description of the issue and its impact;
- reproduction steps or a proof of concept;
- glenv version / commit and Alpine version.

You should receive an acknowledgement within a few days; confirmed issues
are fixed before the next release and credited in the changelog unless you
prefer otherwise.

## Threat model in one paragraph

glenv downloads Debian packages over HTTPS and executes their postinst-less
content as **root** during installation (loader, mounts, caches). The
mitigations are: a single pinned suite (`trixie`) from a mainstream mirror,
SHA256 verification of every `.deb` against the signed-distribution index
fetched over TLS, a plan screen that shows every root action before it
happens, and an `--uninstall` path that removes everything again. The
weakest link in that chain is the trust in the mirror and the TLS root store
used for the fetch — exactly the same trust Alpine's own `apk` places there.

## Scope

In scope: the installer, the router, the preload filter, the tools in this
repository. Out of scope: the Debian packages themselves (report upstream),
the musl host system, and applications you install into the sysroot.
