#!/usr/bin/env python3
"""Debian dependency resolver and package extractor into the glenv sysroot."""
import datetime
import email.utils
import hashlib
import json
import lzma
import os
import re
import shutil
import stat
import tarfile
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import PurePosixPath

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
    provides = {}   # virtual -> [(real name, provided version)]
    with open(os.path.join(DEBS, "Packages")) as f:
        cur = {}
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if cur.get("Package"):
                    index[cur["Package"]] = cur
                    for p in cur.get("Provides", "").split(","):
                        match = re.fullmatch(r"\s*([a-z0-9][a-z0-9+.-]*)(?:\s*\(=\s*([^)]+)\))?\s*", p, re.I)
                        if match:
                            provides.setdefault(match.group(1), []).append(
                                (cur["Package"], match.group(2)))
                cur = {}
                continue
            if line.startswith(" "):
                if cur:
                    key = next(reversed(cur))
                    cur[key] += " " + line.strip()
                continue
            k, _, v = line.partition(":")
            cur[k] = v.strip()
        if cur.get("Package"):
            index[cur["Package"]] = cur
            for p in cur.get("Provides", "").split(","):
                match = re.fullmatch(r"\s*([a-z0-9][a-z0-9+.-]*)(?:\s*\(=\s*([^)]+)\))?\s*", p, re.I)
                if match:
                    provides.setdefault(match.group(1), []).append(
                        (cur["Package"], match.group(2)))
    return index, provides

_DEP_ATOM = re.compile(
    r"^\s*([a-z0-9][a-z0-9+.-]*(?::[a-z0-9]+)?)(?:\s*\(\s*(<<|<=|=|>=|>>)\s*([^)]+)\s*\))?\s*$",
    re.I,
)

def dep_groups(field):
    """Parse Debian dependency clauses without discarding version constraints."""
    if not field.strip():
        return []
    out = []
    for group in field.split(","):
        if not group.strip():
            continue
        alternatives = []
        for raw in group.split("|"):
            match = _DEP_ATOM.fullmatch(raw)
            if not match:
                raise RuntimeError("unsupported Debian dependency syntax: " + raw.strip())
            name = match.group(1).split(":", 1)[0]
            alternatives.append((name, match.group(2), match.group(3)))
        if alternatives:
            out.append(alternatives)
    return out

def _version_part_cmp(left, right):
    """Compare Debian upstream/revision parts using dpkg's verrevcmp ordering."""
    i = j = 0
    while i < len(left) or j < len(right):
        while (i < len(left) and not left[i].isdigit()) or (j < len(right) and not right[j].isdigit()):
            a = left[i] if i < len(left) and not left[i].isdigit() else ""
            b = right[j] if j < len(right) and not right[j].isdigit() else ""
            def order(char):
                if char == "~":
                    return -1
                if not char:
                    return 0
                return ord(char) if char.isalpha() else ord(char) + 256
            if order(a) != order(b):
                return -1 if order(a) < order(b) else 1
            if a:
                i += 1
            if b:
                j += 1
        while i < len(left) and left[i] == "0":
            i += 1
        while j < len(right) and right[j] == "0":
            j += 1
        ai, bj = i, j
        while i < len(left) and left[i].isdigit():
            i += 1
        while j < len(right) and right[j].isdigit():
            j += 1
        a, b = left[ai:i], right[bj:j]
        if len(a) != len(b):
            return -1 if len(a) < len(b) else 1
        if a != b:
            return -1 if a < b else 1
    return 0

def deb_version_cmp(left, right):
    def split(version):
        epoch, separator, rest = version.partition(":")
        if not separator:
            epoch, rest = "0", version
        if not epoch.isdigit():
            raise RuntimeError("invalid Debian version epoch: " + version)
        upstream, separator, revision = rest.rpartition("-")
        if not separator:
            upstream, revision = rest, "0"
        return int(epoch), upstream, revision
    left_epoch, left_upstream, left_revision = split(left)
    right_epoch, right_upstream, right_revision = split(right)
    if left_epoch != right_epoch:
        return -1 if left_epoch < right_epoch else 1
    result = _version_part_cmp(left_upstream, right_upstream)
    return result if result else _version_part_cmp(left_revision, right_revision)

def satisfies(version, operator, required):
    if not operator:
        return True
    result = deb_version_cmp(version, required)
    return {"<<": result < 0, "<=": result <= 0, "=": result == 0,
            ">=": result >= 0, ">>": result > 0}[operator]

def _candidate(name, operator, required, index, provides):
    direct = index.get(name)
    if direct and satisfies(direct.get("Version", "0"), operator, required or ""):
        return direct
    for provider, provided_version in provides.get(name, []):
        pkg = index.get(provider)
        if pkg and (not operator or (provided_version and
                                     satisfies(provided_version, operator, required))):
            return pkg
    return None

def resolve(roots, index, provides):
    selected, order, missing = set(), [], []
    queue = list(roots)
    while queue:
        name, operator, required = queue.pop(0)
        pkg = _candidate(name, operator, required, index, provides)
        if pkg is None:
            clause = name + ((" (" + operator + " " + required + ")") if operator else "")
            missing.append(clause)
            continue
        pkg_name = pkg["Package"]
        if pkg_name in selected:
            continue
        selected.add(pkg_name)
        order.append(pkg)
        fields = ", ".join(x for x in (pkg.get("Pre-Depends", ""), pkg.get("Depends", "")) if x)
        for group in dep_groups(fields):
            choice = None
            for alt_name, alt_operator, alt_required in group:
                if _candidate(alt_name, alt_operator, alt_required, index, provides):
                    choice = (alt_name, alt_operator, alt_required)
                    break
            if choice:
                queue.append(choice)
            else:
                missing.append(" | ".join(x[0] + ((" (" + x[1] + " " + x[2] + ")") if x[1] else "")
                                           for x in group))
    return order, missing

def _safe_relative(name):
    while name.startswith("./"):
        name = name[2:]
    if name in ("", "."):
        return ""
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise RuntimeError("unsafe path in Debian package: " + name)
    return path.as_posix()

def _safe_extract_tar(archive, destination):
    seen_links = set()
    with tarfile.open(archive, "r:*") as tar:
        for member in tar:
            name = _safe_relative(member.name)
            if not name:
                if member.isdir():
                    continue
                raise RuntimeError("empty path in Debian package")
            parts = PurePosixPath(name).parts
            for count in range(1, len(parts)):
                ancestor = "/".join(parts[:count])
                ancestor_path = os.path.join(destination, *parts[:count])
                if ancestor in seen_links or os.path.islink(ancestor_path):
                    raise RuntimeError("package path traverses a symlink: " + name)
            target = os.path.join(destination, *parts)
            if member.isdir():
                if os.path.lexists(target) and (os.path.islink(target) or not os.path.isdir(target)):
                    raise RuntimeError("package directory conflicts with an existing path: " + name)
                os.makedirs(target, exist_ok=True)
            elif member.isfile():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.isdir(target) and not os.path.islink(target):
                    raise RuntimeError("package file conflicts with a directory: " + name)
                source = tar.extractfile(member)
                if source is None:
                    raise RuntimeError("cannot read package member: " + name)
                with tempfile.NamedTemporaryFile(prefix=".glenv-", dir=os.path.dirname(target),
                                                 delete=False) as output:
                    temp_path = output.name
                    with source:
                        shutil.copyfileobj(source, output)
                os.chmod(temp_path, member.mode & 0o777)
                os.replace(temp_path, target)
            elif member.issym():
                link = member.linkname
                if not link:
                    raise RuntimeError("empty symlink in Debian package: " + name)
                if not os.path.isabs(link):
                    resolved = os.path.normpath(os.path.join(os.path.dirname(name), link))
                    if resolved == ".." or resolved.startswith("../"):
                        raise RuntimeError("symlink escapes sysroot: " + name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.lexists(target):
                    if os.path.isdir(target) and not os.path.islink(target):
                        raise RuntimeError("package symlink conflicts with a directory: " + name)
                    os.unlink(target)
                fd, temp_path = tempfile.mkstemp(prefix=".glenv-", dir=os.path.dirname(target))
                os.close(fd)
                os.unlink(temp_path)
                os.symlink(link, temp_path)
                os.replace(temp_path, target)
                seen_links.add(name)
            elif member.islnk():
                source_rel = _safe_relative(member.linkname)
                source = os.path.join(destination, *PurePosixPath(source_rel).parts)
                if not os.path.isfile(source) or os.path.islink(source):
                    raise RuntimeError("invalid hardlink target in Debian package: " + name)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(source, target)
            else:
                raise RuntimeError("unsupported special file in Debian package: " + name)

def _ar_members(path):
    members = []
    string_table = b""
    archive_size = os.path.getsize(path)
    with open(path, "rb") as archive:
        if archive.read(8) != b"!<arch>\n":
            raise RuntimeError("not a Debian ar archive")
        while True:
            header = archive.read(60)
            if not header:
                break
            if len(header) != 60 or header[58:60] != bytes((96, 10)):
                raise RuntimeError("malformed Debian ar member header")
            try:
                size = int(header[48:58].decode("ascii").strip())
                raw_name = header[:16].decode("ascii").strip()
            except (UnicodeDecodeError, ValueError):
                raise RuntimeError("invalid Debian ar member header")
            data_offset = archive.tell()
            if size < 0 or data_offset + size > archive_size:
                raise RuntimeError("truncated Debian ar member")
            if raw_name == "//":
                string_table = archive.read(size)
            elif raw_name in ("/", "/SYM64/"):
                archive.seek(data_offset + size)
            else:
                member_size = size
                if raw_name.startswith("#1/"):
                    try:
                        name_size = int(raw_name[3:])
                    except ValueError:
                        raise RuntimeError("invalid BSD ar member name")
                    if name_size <= 0 or name_size > size:
                        raise RuntimeError("invalid BSD ar member name length")
                    name = archive.read(name_size).decode("utf-8", "strict").rstrip(chr(0))
                    data_offset += name_size
                    member_size -= name_size
                elif raw_name.startswith("/") and raw_name[1:].isdigit():
                    index = int(raw_name[1:])
                    if index >= len(string_table):
                        raise RuntimeError("invalid GNU ar string-table reference")
                    end = string_table.find(b"/\n", index)
                    if end < 0:
                        raise RuntimeError("unterminated GNU ar string-table name")
                    name = string_table[index:end].decode("utf-8", "strict")
                else:
                    name = raw_name.rstrip("/")
                members.append({"name": name, "offset": data_offset, "size": member_size})
                archive.seek(data_offset + member_size)
            if size % 2:
                archive.seek(archive.tell() + 1)
    return members

def _copy_ar_member(archive_path, member, destination):
    remaining = member["size"]
    with open(archive_path, "rb") as source, open(destination, "wb") as output:
        source.seek(member["offset"])
        while remaining:
            block = source.read(min(1024 * 1024, remaining))
            if not block:
                raise RuntimeError("truncated Debian ar member: " + member["name"])
            output.write(block)
            remaining -= len(block)

def _tar_bytes_for_member(deb_path, member, temp_dir):
    path = os.path.join(temp_dir, "control-data")
    _copy_ar_member(deb_path, member, path)
    if not member["name"].endswith(".zst"):
        return path
    zstd = shutil.which("zstd")
    if not zstd:
        raise RuntimeError("zstd is required to read this Debian package")
    tar_path = os.path.join(temp_dir, "control.tar")
    with open(tar_path, "wb") as output:
        subprocess.run([zstd, "-dc", path], check=True, stdout=output)
    return tar_path

def _deb_control_fields(deb_path):
    members = _ar_members(deb_path)
    controls = [member for member in members
                if re.fullmatch(r"control\.tar(?:\.(?:xz|gz|bz2|lzma|zst))?", member["name"])]
    if len(controls) != 1:
        raise RuntimeError("expected exactly one supported control.tar member")
    with tempfile.TemporaryDirectory(prefix="glenv-deb-control-") as tmp:
        tar_path = _tar_bytes_for_member(deb_path, controls[0], tmp)
        with tarfile.open(tar_path, "r:*") as tar:
            control = next((member for member in tar
                            if _safe_relative(member.name) == "control" and member.isfile()), None)
            if control is None:
                raise RuntimeError("Debian control archive has no regular control file")
            stream = tar.extractfile(control)
            if stream is None:
                raise RuntimeError("cannot read Debian control file")
            data = stream.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise RuntimeError("Debian control file is too large")
    fields = {}
    current = None
    for line in data.decode("utf-8", "strict").splitlines():
        if line.startswith((" ", "\t")):
            if current:
                fields[current] += " " + line.strip()
            continue
        key, separator, value = line.partition(":")
        if separator:
            current = key
            fields[key] = value.strip()
    for required in ("Package", "Version", "Architecture"):
        if not fields.get(required):
            raise RuntimeError("Debian control file is missing " + required)
    return fields

def verify_local_deb(path, index):
    try:
        os.lstat(path)
    except OSError as error:
        raise RuntimeError("cannot inspect local .deb: " + str(error))
    if not os.path.isfile(path) or os.path.islink(path):
        raise RuntimeError("local .deb must be a regular file")
    fields = _deb_control_fields(path)
    if fields["Architecture"] not in (ARCH, "all"):
        raise RuntimeError("local .deb architecture does not match " + ARCH)
    pkg = index.get(fields["Package"])
    if not pkg or pkg.get("Version") != fields["Version"] or \
       pkg.get("Architecture") not in (ARCH, "all"):
        raise RuntimeError("local .deb package/version is not present in the authenticated Debian index")
    verify_sha256(path, pkg.get("SHA256", ""))
    return pkg

def snapshot_local_deb(path, expected_sha256, destination_dir):
    """Copy an authenticated local archive into private storage before extraction."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        source_fd = os.open(path, flags)
    except OSError as error:
        raise RuntimeError("cannot safely open local .deb: " + str(error))
    snapshot = None
    try:
        if not stat.S_ISREG(os.fstat(source_fd).st_mode):
            raise RuntimeError("local .deb must be a regular file")
        digest = hashlib.sha256()
        with os.fdopen(source_fd, "rb") as source:
            source_fd = None
            with tempfile.NamedTemporaryFile(prefix="glenv-local-deb-", dir=destination_dir,
                                             delete=False) as target:
                snapshot = target.name
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    target.write(block)
                    digest.update(block)
                target.flush()
                os.fsync(target.fileno())
        if digest.hexdigest() != expected_sha256:
            raise RuntimeError("SHA256 mismatch")
        return snapshot
    except Exception:
        if snapshot and os.path.lexists(snapshot):
            os.unlink(snapshot)
        raise
    finally:
        if source_fd is not None:
            os.close(source_fd)

def extract(deb_path, destination):
    members = _ar_members(deb_path)
    data_members = [member for member in members
                    if re.fullmatch(r"data\.tar(?:\.(?:xz|gz|bz2|lzma|zst))?", member["name"])]
    if len(data_members) != 1:
        raise RuntimeError("expected exactly one supported data.tar member in " + deb_path)
    with tempfile.NamedTemporaryFile(prefix="glenv-data-", dir=os.path.dirname(destination),
                                     delete=False) as stream:
        data_path = stream.name
    try:
        _copy_ar_member(deb_path, data_members[0], data_path)
        if data_members[0]["name"].endswith(".zst"):
            zstd = shutil.which("zstd")
            if not zstd:
                raise RuntimeError("zstd is required to extract this Debian package")
            with tempfile.NamedTemporaryFile(prefix="glenv-untar-", dir=os.path.dirname(destination),
                                             delete=False) as stream:
                tar_path = stream.name
            try:
                with open(tar_path, "wb") as output:
                    subprocess.run([zstd, "-dc", data_path], check=True, stdout=output)
                _safe_extract_tar(tar_path, destination)
            finally:
                os.unlink(tar_path)
        else:
            _safe_extract_tar(data_path, destination)
    finally:
        os.unlink(data_path)

def _archive_paths(root):
    dirs, leaves = [], []
    for current, names, files in os.walk(root, topdown=True, followlinks=False):
        names[:] = sorted(names)
        files.sort()
        for name in list(names):
            path = os.path.join(current, name)
            if os.path.islink(path):
                names.remove(name)
                leaves.append(path)
            else:
                dirs.append(path)
        leaves.extend(os.path.join(current, name) for name in files)
    return dirs, leaves

def _state(path):
    if os.path.islink(path):
        return {"type": "symlink", "value": os.readlink(path)}
    if os.path.isfile(path):
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return {"type": "file", "sha256": digest.hexdigest()}
    if os.path.lexists(path):
        raise RuntimeError("unsupported non-file package path: " + path)
    return {"type": "missing"}

def _copy_leaf(source, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=".glenv-", dir=os.path.dirname(target))
    os.close(fd)
    if os.path.islink(source):
        os.unlink(temp_path)
        os.symlink(os.readlink(source), temp_path)
    else:
        shutil.copy2(source, temp_path)
    os.replace(temp_path, target)

def _append_journal(path, event):
    with open(path, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())

def merge_staged_tree(stage, sysroot, transaction_dir):
    os.makedirs(sysroot, exist_ok=True)
    backup_dir = os.path.join(transaction_dir, "backup")
    os.makedirs(backup_dir)
    journal_path = os.path.join(transaction_dir, "journal.jsonl")
    _append_journal(journal_path, {"type": "begin"})
    dirs, leaves = _archive_paths(stage)
    dirs.sort(key=lambda path: (path.count(os.sep), path))
    leaves.sort()
    created_dirs, changes = [], []
    for path in dirs:
        rel = os.path.relpath(path, stage)
        target = os.path.join(sysroot, rel)
        if os.path.lexists(target) and (os.path.islink(target) or not os.path.isdir(target)):
            raise RuntimeError("sysroot directory conflicts with an existing path: " + rel)
    for path in leaves:
        rel = os.path.relpath(path, stage)
        target = os.path.join(sysroot, rel)
        cursor = os.path.dirname(target)
        while cursor != sysroot and cursor.startswith(sysroot + os.sep):
            if os.path.islink(cursor):
                raise RuntimeError("sysroot path traverses a symlink: " + rel)
            cursor = os.path.dirname(cursor)
        if os.path.isdir(target) and not os.path.islink(target):
            raise RuntimeError("sysroot file conflicts with a directory: " + rel)
    try:
        for path in dirs:
            rel = os.path.relpath(path, stage)
            target = os.path.join(sysroot, rel)
            if not os.path.exists(target):
                rel_posix = rel.replace(os.sep, "/")
                _append_journal(journal_path, {"type": "directory", "path": rel_posix})
                os.mkdir(target)
                created_dirs.append(rel_posix)
        for number, path in enumerate(leaves):
            rel = os.path.relpath(path, stage)
            target = os.path.join(sysroot, rel)
            before = _state(target)
            backup_name = str(number)
            if before["type"] == "symlink":
                os.symlink(before["value"], os.path.join(backup_dir, backup_name))
            elif before["type"] == "file":
                shutil.copy2(target, os.path.join(backup_dir, backup_name))
            change = {"path": rel.replace(os.sep, "/"), "before": before,
                      "backup": backup_name if before["type"] != "missing" else None,
                      "after": _state(path)}
            _append_journal(journal_path, {"type": "file", "change": change})
            changes.append(change)
            _copy_leaf(path, target)
    except Exception:
        for change in reversed(changes):
            target = os.path.join(sysroot, *PurePosixPath(change["path"]).parts)
            if os.path.lexists(target):
                if os.path.isdir(target) and not os.path.islink(target):
                    shutil.rmtree(target)
                else:
                    os.unlink(target)
            before = change["before"]
            if before["type"] == "symlink":
                os.symlink(before["value"], target)
            elif before["type"] == "file":
                _copy_leaf(os.path.join(backup_dir, change["backup"]), target)
        for rel in reversed(created_dirs):
            try:
                os.rmdir(os.path.join(sysroot, *PurePosixPath(rel).parts))
            except OSError:
                pass
        raise
    return {"changes": changes, "created_dirs": created_dirs}

def recover_pending_transaction(transaction_dir, sysroot):
    journal_path = os.path.join(transaction_dir, "journal.jsonl")
    if not os.path.isfile(journal_path):
        return
    with open(journal_path, encoding="utf-8") as stream:
        events = [json.loads(line) for line in stream if line.strip()]
    changes = [event["change"] for event in events if event.get("type") == "file"]
    created_dirs = [event["path"] for event in events if event.get("type") == "directory"]
    backup_dir = os.path.join(transaction_dir, "backup")
    for change in reversed(changes):
        rel = _safe_relative(change["path"])
        target = os.path.join(sysroot, *PurePosixPath(rel).parts)
        current = _state(target)
        if current == change["before"]:
            continue
        if current != change["after"]:
            raise RuntimeError("cannot recover interrupted update; file changed: " + rel)
        before = change["before"]
        if os.path.lexists(target):
            os.unlink(target)
        if before["type"] == "file":
            backup = os.path.join(backup_dir, change["backup"])
            if not os.path.isfile(backup):
                raise RuntimeError("cannot recover interrupted update; backup missing: " + rel)
            _copy_leaf(backup, target)
        elif before["type"] == "symlink":
            os.symlink(before["value"], target)
    for rel in reversed(created_dirs):
        try:
            os.rmdir(os.path.join(sysroot, *PurePosixPath(rel).parts))
        except OSError:
            pass

def recover_pending_transactions():
    history_root = os.path.join(PREFIX, "history")
    if not os.path.isdir(history_root):
        return
    for name in sorted(os.listdir(history_root)):
        if not name.startswith(".pending-"):
            continue
        path = os.path.join(history_root, name)
        try:
            recover_pending_transaction(path, SYSROOT)
        except Exception as error:
            raise RuntimeError("interrupted transaction needs recovery at " + path + ": " + str(error))
        shutil.rmtree(path)

def rollback_entry(entry, transaction_dir=None):
    if transaction_dir is None:
        transaction_dir = os.path.join(PREFIX, "history", entry["id"])
    changes = entry.get("changes", [])
    for change in changes:
        rel = _safe_relative(change["path"])
        target = os.path.join(SYSROOT, *PurePosixPath(rel).parts)
        cursor = os.path.dirname(target)
        while cursor != SYSROOT and cursor.startswith(SYSROOT + os.sep):
            if os.path.islink(cursor):
                raise RuntimeError("rollback path traverses a sysroot symlink: " + rel)
            cursor = os.path.dirname(cursor)
        if _state(target) != change["after"]:
            raise RuntimeError("rollback refused: sysroot file changed since transaction: " + rel)
        if change["before"]["type"] != "missing":
            backup = os.path.join(transaction_dir, "backup", change["backup"])
            if not os.path.lexists(backup):
                raise RuntimeError("rollback backup is missing: " + rel)
    with tempfile.TemporaryDirectory(prefix="glenv-rollback-", dir=PREFIX) as safety:
        safety_paths = []
        try:
            for number, change in enumerate(changes):
                target = os.path.join(SYSROOT, *PurePosixPath(change["path"]).parts)
                snapshot = os.path.join(safety, str(number))
                state = _state(target)
                if state["type"] == "file":
                    shutil.copy2(target, snapshot)
                elif state["type"] == "symlink":
                    os.symlink(state["value"], snapshot)
                safety_paths.append((target, snapshot, state))
                if os.path.lexists(target):
                    os.unlink(target)
                before = change["before"]
                if before["type"] == "file":
                    _copy_leaf(os.path.join(transaction_dir, "backup", change["backup"]), target)
                elif before["type"] == "symlink":
                    fd, temp_path = tempfile.mkstemp(prefix=".glenv-", dir=os.path.dirname(target))
                    os.close(fd)
                    os.unlink(temp_path)
                    os.symlink(before["value"], temp_path)
                    os.replace(temp_path, target)
            for rel in reversed(entry.get("created_dirs", [])):
                try:
                    os.rmdir(os.path.join(SYSROOT, *PurePosixPath(rel).parts))
                except OSError:
                    pass
        except Exception:
            for target, snapshot, state in reversed(safety_paths):
                if os.path.lexists(target):
                    os.unlink(target)
                if state["type"] == "file":
                    _copy_leaf(snapshot, target)
                elif state["type"] == "symlink":
                    os.symlink(state["value"], target)
            raise

def _download_verified(pkg, temp_dir):
    filename = pkg.get("Filename", "")
    relative = PurePosixPath(filename)
    if relative.is_absolute() or not relative.parts or any(part in ("", ".", "..") for part in relative.parts):
        raise RuntimeError("unsafe Filename in signed Debian index: " + filename)
    cached = os.path.join(DEBS, os.path.basename(filename))
    if os.path.isfile(cached):
        try:
            verify_sha256(cached, pkg.get("SHA256", ""))
            return cached
        except RuntimeError:
            pass
    path = os.path.join(temp_dir, os.path.basename(filename))
    urllib.request.urlretrieve(MIRROR + filename, path)
    verify_sha256(path, pkg.get("SHA256", ""))
    return path

def _write_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".glenv-json-",
                                     dir=os.path.dirname(path), delete=False) as stream:
        temp_path = stream.name
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(temp_path, path)

def _history_entries():
    root = os.path.join(PREFIX, "history")
    if not os.path.isdir(root):
        return []
    entries = []
    for name in os.listdir(root):
        path = os.path.join(root, name, "manifest.json")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as stream:
            entry = json.load(stream)
        entry["id"] = name
        entries.append(entry)
    return sorted(entries, key=lambda item: item.get("created", ""), reverse=True)

def main():
    args = sys.argv[1:]
    recover_pending_transactions()
    if args and args[0] == "--update-index":
        if len(args) != 1:
            raise RuntimeError("usage: fetch-deps.py --update-index")
        update_index()
        return
    if args and args[0] in ("history", "--history"):
        for entry in _history_entries():
            state = "rolled back" if entry.get("rolled_back") else "active"
            print("{}  {}  {}  {}".format(entry["id"], state, entry.get("created", "?"),
                                          ", ".join(entry.get("packages", []))))
        return
    if args and args[0] == "rollback":
        entries = _history_entries()
        if len(args) > 2:
            raise RuntimeError("usage: fetch-deps.py rollback [transaction-id]")
        requested = args[1] if len(args) == 2 else None
        latest = next((item for item in entries if not item.get("rolled_back")), None)
        if requested and (latest is None or requested != latest["id"]):
            raise RuntimeError("only the latest active transaction can be rolled back")
        entry = latest
        if entry is None:
            raise RuntimeError("no matching active transaction to roll back")
        if entry.get("rolled_back"):
            raise RuntimeError("transaction is already rolled back: " + entry["id"])
        rollback_entry(entry)
        entry["rolled_back"] = True
        _write_json(os.path.join(PREFIX, "history", entry["id"], "manifest.json"), entry)
        print("Rolled back transaction " + entry["id"])
        return
    local_deb = None
    local_pkg = None
    index = provides = None
    if args and args[0] == "--deb-file":
        if len(args) != 2:
            raise RuntimeError("usage: fetch-deps.py --deb-file path.deb")
        local_deb = args[1]
        update_index()
        index, provides = parse_packages()
        local_pkg = verify_local_deb(local_deb, index)
        roots = [local_pkg["Package"]]
    elif args and args[0] == "upgrade":
        if len(args) != 1:
            raise RuntimeError("usage: fetch-deps.py upgrade")
        update_index()
        roots = sorted({name for entry in _history_entries() if not entry.get("rolled_back")
                        for name in entry.get("packages", [])})
        if not roots:
            raise RuntimeError("no active Debian package transactions to upgrade")
    else:
        if args and args[0] in ("--update", "update"):
            update_index()
            args = args[1:]
        roots = args
    if not roots:
        print("usage: fetch-deps.py pkg...", file=sys.stderr)
        sys.exit(2)
    if index is None:
        index, provides = parse_packages()
    pkgs, missing = resolve([(name, None, None) for name in roots], index, provides)
    if missing:
        raise RuntimeError("dependency resolution failed; unavailable or incompatible: " +
                           ", ".join(sorted(set(missing))))
    total = len(pkgs)
    print(f"To download: {total} packages")
    os.makedirs(PREFIX, exist_ok=True)
    history_dir = os.path.join(PREFIX, "history")
    os.makedirs(history_dir, exist_ok=True)
    transaction_dir = tempfile.mkdtemp(prefix=".pending-", dir=history_dir)
    stage = os.path.join(transaction_dir, "sysroot-stage")
    os.makedirs(stage)
    manifest = None
    identifier = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + os.path.basename(transaction_dir)[-8:]
    preserve_transaction = False
    try:
        with tempfile.TemporaryDirectory(prefix="glenv-download-", dir=PREFIX) as download_dir:
            downloaded = []
            for number, pkg in enumerate(pkgs, 1):
                if local_deb and pkg["Package"] == local_pkg["Package"]:
                    path = snapshot_local_deb(local_deb, pkg.get("SHA256", ""), download_dir)
                else:
                    path = _download_verified(pkg, download_dir)
                extract(path, stage)
                downloaded.append((pkg, path))
                print(f"[{number}/{total}] verified and staged {pkg['Package']}")
            os.makedirs(DEBS, exist_ok=True)
            for pkg, path in downloaded:
                final = os.path.join(DEBS, os.path.basename(pkg["Filename"]))
                if os.path.dirname(path) != DEBS:
                    shutil.copy2(path, final + ".glenv-new")
                    os.replace(final + ".glenv-new", final)
            changes = merge_staged_tree(stage, SYSROOT, transaction_dir)
            manifest = dict(changes, id=identifier,
                            created=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                            packages=[pkg["Package"] for pkg in pkgs], rolled_back=False)
            shutil.rmtree(stage)
            _write_json(os.path.join(transaction_dir, "manifest.json"), manifest)
            final_dir = os.path.join(history_dir, identifier)
            os.replace(transaction_dir, final_dir)
            transaction_dir = None
        print(f"Done: {total} packages installed successfully; transaction {identifier}")
    except Exception:
        if transaction_dir and os.path.isdir(transaction_dir):
            try:
                recover_pending_transaction(transaction_dir, SYSROOT)
            except Exception as rollback_error:
                preserve_transaction = True
                print("CRITICAL: automatic recovery failed; recovery data remains at " +
                      transaction_dir + ": " + str(rollback_error), file=sys.stderr)
        if transaction_dir and not preserve_transaction:
            shutil.rmtree(transaction_dir, ignore_errors=True)
        raise

if __name__ == "__main__":
    main()
