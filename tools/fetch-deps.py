#!/usr/bin/env python3
"""Debian dependency resolver and package extractor into the glenv sysroot."""
import datetime
import email.utils
import glob
import hashlib
import lzma
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

PREFIX = os.environ.get("GLENV_PREFIX") or ("/opt/glibc-env" if os.path.isdir("/opt/glibc-env/sysroot") else os.path.expanduser("~/glibc-env"))
DEBS = os.path.join(PREFIX, "debs")
SYSROOT = os.path.join(PREFIX, "sysroot")
MIRROR = os.environ.get("GLENV_MIRROR", "https://deb.debian.org/debian").rstrip("/") + "/"
DIST = os.environ.get("GLENV_DIST", "trixie")
ARCH = os.environ.get("GLENV_DEBIAN_ARCH", "amd64")

def verify_sha256(path, expected):
    if not expected:
        raise RuntimeError("Debian index has no SHA256 for this package")
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    if h.hexdigest() != expected:
        raise RuntimeError("SHA256 mismatch")

def update_index():
    """Download and authenticate Debian's signed Release and Packages index."""
    os.makedirs(DEBS, exist_ok=True)
    base = f"{MIRROR}dists/{DIST}/"
    with tempfile.TemporaryDirectory(prefix="glenv-index-", dir=DEBS) as tmp:
        inrelease = os.path.join(tmp, "InRelease")
        release = os.path.join(tmp, "Release")
        xz_path = os.path.join(tmp, "Packages.xz")
        print(f"index: {base}InRelease")
        urllib.request.urlretrieve(base + "InRelease", inrelease)
        verify_release_signature(inrelease, release)
        reject_release_rollback(release)
        expected_sha, expected_size = release_index_digest(release)
        package_url = base + f"main/binary-{ARCH}/Packages.xz"
        print(f"index: {package_url}")
        urllib.request.urlretrieve(package_url, xz_path)
        verify_index_payload(release, xz_path, expected_sha, expected_size)
        packages_path = os.path.join(tmp, "Packages")
        with lzma.open(xz_path) as src, open(packages_path, "wb") as dst:
            shutil.copyfileobj(src, dst)
        # Each file is replaced atomically. A crash between replacements leaves
        # a mismatched bundle which is rejected on the next invocation.
        for source, name in ((inrelease, "InRelease"), (xz_path, "Packages.xz"),
                             (packages_path, "Packages")):
            os.replace(source, os.path.join(DEBS, name))
    print("index ready:", os.path.join(DEBS, "Packages"))

def release_fields(release_path):
    fields = {}
    with open(release_path, encoding="utf-8") as stream:
        for line in stream:
            if not line or line[0].isspace():
                continue
            key, sep, value = line.partition(":")
            if sep:
                fields[key] = value.strip()
    return fields

def release_index_digest(release_path):
    fields = release_fields(release_path)
    if fields.get("Codename") != DIST:
        raise RuntimeError("signed Debian index codename mismatch")
    if ARCH not in fields.get("Architectures", "").split():
        raise RuntimeError(f"signed Debian index does not include {ARCH}")
    if "main" not in fields.get("Components", "").split():
        raise RuntimeError("signed Debian index does not include main")
    now = datetime.datetime.now(datetime.timezone.utc)
    release_date = fields.get("Date")
    if not release_date:
        raise RuntimeError("signed Debian index has no Date")
    released = email.utils.parsedate_to_datetime(release_date)
    if released.tzinfo is None:
        released = released.replace(tzinfo=datetime.timezone.utc)
    if released > now + datetime.timedelta(minutes=10):
        raise RuntimeError("signed Debian index Date is in the future")
    # Debian stable InRelease files may omit Valid-Until. When present, enforce
    # it; otherwise reject metadata rollback against a previously accepted date.
    valid_until = fields.get("Valid-Until")
    if valid_until:
        expiry = email.utils.parsedate_to_datetime(valid_until)
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        if expiry <= now:
            raise RuntimeError("signed Debian index has expired")

    expected_path = f"main/binary-{ARCH}/Packages.xz"
    in_sha256 = False
    with open(release_path, encoding="utf-8") as stream:
        for line in stream:
            if line.rstrip("\r\n") == "SHA256:":
                in_sha256 = True
                continue
            if line and not line[0].isspace():
                in_sha256 = False
            if in_sha256:
                parts = line.split()
                if len(parts) == 3 and parts[2] == expected_path:
                    digest, size = parts[0], parts[1]
                    if not re.fullmatch(r"[0-9a-fA-F]{64}", digest) or not size.isdigit():
                        raise RuntimeError("malformed Packages.xz checksum in signed index")
                    return digest.lower(), int(size)
    raise RuntimeError("signed index has no SHA256 for Packages.xz")

def reject_release_rollback(new_release):
    inrelease = os.path.join(DEBS, "InRelease")
    if not os.path.isfile(inrelease):
        return
    with tempfile.TemporaryDirectory(prefix="glenv-previous-") as tmp:
        previous_release = os.path.join(tmp, "Release")
        try:
            verify_release_signature(inrelease, previous_release)
        except RuntimeError:
            return
        try:
            old_date = release_fields(previous_release).get("Date")
            new_date = release_fields(new_release).get("Date")
            if old_date and new_date:
                old = email.utils.parsedate_to_datetime(old_date)
                new = email.utils.parsedate_to_datetime(new_date)
                if old.tzinfo is None:
                    old = old.replace(tzinfo=datetime.timezone.utc)
                if new.tzinfo is None:
                    new = new.replace(tzinfo=datetime.timezone.utc)
                if new < old:
                    raise RuntimeError("signed Debian index is older than the previously accepted index")
        except (ValueError, TypeError):
            # An unverifiable or malformed old cache is not a trust anchor.
            return

def verify_release_signature(inrelease, release):
    keyring = "/usr/share/keyrings/debian-archive-keyring.pgp"
    if not os.path.isfile(keyring) or not os.path.getsize(keyring):
        keyring = "/usr/share/keyrings/debian-archive-keyring.gpg"
    if not os.path.isfile(keyring) or not os.path.getsize(keyring):
        raise RuntimeError("Debian archive keyring not found; install debian-archive-keyring")
    if not shutil.which("gpgv"):
        raise RuntimeError("gpgv not found; install gpgv")
    result = subprocess.run(
        ["gpgv", "--keyring", keyring, "--output", release, inrelease],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if result.returncode:
        raise RuntimeError("Debian InRelease signature verification failed: " + result.stderr.strip())

def verify_index_payload(release_path, packages_xz, expected_sha=None, expected_size=None):
    if expected_sha is None or expected_size is None:
        expected_sha, expected_size = release_index_digest(release_path)
    actual_size = os.path.getsize(packages_xz)
    if actual_size != expected_size:
        raise RuntimeError("Packages.xz size does not match signed Debian index")
    h = hashlib.sha256()
    with open(packages_xz, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    if h.hexdigest() != expected_sha:
        raise RuntimeError("Packages.xz SHA256 does not match signed Debian index")

def verify_cached_index():
    inrelease = os.path.join(DEBS, "InRelease")
    packages_xz = os.path.join(DEBS, "Packages.xz")
    if not os.path.isfile(inrelease) or not os.path.isfile(packages_xz):
        raise RuntimeError("authenticated Debian index bundle missing; run fetch-deps.py --update")
    if time.time() - os.path.getmtime(inrelease) > 24 * 60 * 60:
        raise RuntimeError("authenticated Debian index cache is older than 24 hours; run fetch-deps.py --update")
    with tempfile.TemporaryDirectory(prefix="glenv-verify-") as tmp:
        release = os.path.join(tmp, "Release")
        verify_release_signature(inrelease, release)
        verify_index_payload(release, packages_xz)
        # Ensure a stale or replaced decompressed cache cannot bypass the
        # authenticated Packages.xz file.
        cached = os.path.join(DEBS, "Packages")
        with lzma.open(packages_xz) as src:
            digest = hashlib.sha256()
            for block in iter(lambda: src.read(1024 * 1024), b""):
                digest.update(block)
        if not os.path.isfile(cached) or _sha256_file(cached) != digest.hexdigest():
            raise RuntimeError("cached Packages differs from its authenticated Packages.xz")

def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def parse_packages():
    verify_cached_index()
    index = {}      # name -> pkg dict
    provides = {}   # virtual -> real names
    with open(os.path.join(DEBS, "Packages")) as f:
        cur = {}
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if cur.get("Package"):
                    index[cur["Package"]] = cur
                    for p in cur.get("Provides", "").split(","):
                        p = p.strip().split("(")[0].strip()
                        if p:
                            provides.setdefault(p, []).append(cur["Package"])
                cur = {}
                continue
            if line.startswith(" "):
                continue
            k, _, v = line.partition(":")
            cur[k] = v.strip()
        if cur.get("Package"):
            index[cur["Package"]] = cur
    return index, provides

def dep_names(field):
    """'a (>= 1), b | c, d' -> [['a','b','c'], ['d']]"""
    out = []
    for grp in field.split(","):
        alts = [re.sub(r"\(.*?\)", "", a).strip() for a in grp.split("|")]
        alts = [a for a in alts if a]
        if alts:
            out.append(alts)
    return out

def resolve(roots, index, provides):
    seen, order, missing = set(), [], []
    queue = list(roots)
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.add(name)
        pkg = index.get(name)
        if pkg is None:
            # virtual package — take the first provider
            prov = provides.get(name)
            if prov:
                for p in prov:
                    if p not in seen and p in index:
                        queue.append(p)
                        break
                else:
                    missing.append(name)
            else:
                missing.append(name)
            continue
        order.append(pkg)
        for grp in dep_names(pkg.get("Depends", "") + ", " + pkg.get("Pre-Depends", "")):
            for alt in grp:
                if alt in seen or alt in index or alt in provides:
                    queue.append(alt)
                    break
    return order, missing

def extract(deb_path):
    tmp = os.path.join(DEBS, ".x")
    subprocess.run(["rm", "-rf", tmp], check=True)
    os.makedirs(tmp, exist_ok=True)
    subprocess.run(["ar", "x", "--output=" + tmp, deb_path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    datas = glob.glob(os.path.join(tmp, "data.tar.*"))
    if not datas:
        raise RuntimeError("no data.tar in " + deb_path)
    d = datas[0]
    r = subprocess.run(["tar", "-xf", d, "-C", SYSROOT])
    if r.returncode != 0:
        with open(d, "rb") as fb:
            subprocess.run(["tar", "-x", "-C", SYSROOT], stdin=fb, check=True)
    subprocess.run(["rm", "-rf", tmp], check=True)

def main():
    args = sys.argv[1:]
    if args and args[0] in ("--update", "update"):
        update_index()
        args = args[1:]
    roots = args
    if not roots:
        print("usage: fetch-deps.py pkg...", file=sys.stderr)
        sys.exit(2)
    index, provides = parse_packages()
    pkgs, missing = resolve(roots, index, provides)
    if missing:
        print("WARNING, not found:", ", ".join(sorted(set(missing))))
    total = len(pkgs)
    print(f"To download: {total} packages")
    ok = fail = 0
    for i, pkg in enumerate(pkgs, 1):
        fn = pkg["Filename"]
        local = os.path.join(DEBS, os.path.basename(fn))
        if not os.path.exists(local):
            try:
                urllib.request.urlretrieve(MIRROR + fn, local)
            except Exception as e:
                print(f"[{i}/{total}] FAIL {pkg['Package']}: {e}")
                fail += 1
                continue
        try:
            verify_sha256(local, pkg.get("SHA256", ""))
            extract(local)
            ok += 1
        except Exception as e:
            try:
                os.unlink(local)
            except OSError:
                pass
            print(f"[{i}/{total}] EXTRACT FAIL {pkg['Package']}: {e}")
            fail += 1
        if i % 25 == 0 or i == total:
            print(f"[{i}/{total}] ok={ok} fail={fail}")
    print(f"Done: ok={ok} fail={fail}")

if __name__ == "__main__":
    main()
