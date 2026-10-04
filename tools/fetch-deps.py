#!/usr/bin/env python3
"""Debian dependency resolver and package extractor into the glenv sysroot."""
import os, sys, re, subprocess, urllib.request, glob

PREFIX = os.environ.get("GLENV_PREFIX") or ("/opt/glibc-env" if os.path.isdir("/opt/glibc-env/sysroot") else os.path.expanduser("~/glibc-env"))
DEBS = os.path.join(PREFIX, "debs")
SYSROOT = os.path.join(PREFIX, "sysroot")
MIRROR = "https://deb.debian.org/debian/"
DIST = "trixie"
ARCH = "amd64"

def update_index():
    """Download a fresh Debian Packages index into DEBS/ (for a clean install)."""
    import lzma, shutil
    os.makedirs(DEBS, exist_ok=True)
    url = f"{MIRROR}dists/{DIST}/main/binary-{ARCH}/Packages.xz"
    xz_path = os.path.join(DEBS, "Packages.xz")
    print(f"index: {url}")
    urllib.request.urlretrieve(url, xz_path)
    with lzma.open(xz_path) as src, open(os.path.join(DEBS, "Packages"), "wb") as dst:
        shutil.copyfileobj(src, dst)
    print("index ready:", os.path.join(DEBS, "Packages"))

def parse_packages():
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
            extract(local)
            ok += 1
        except Exception as e:
            print(f"[{i}/{total}] EXTRACT FAIL {pkg['Package']}: {e}")
            fail += 1
        if i % 25 == 0 or i == total:
            print(f"[{i}/{total}] ok={ok} fail={fail}")
    print(f"Done: ok={ok} fail={fail}")

if __name__ == "__main__":
    main()
