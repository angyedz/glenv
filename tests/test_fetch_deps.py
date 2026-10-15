#!/usr/bin/env python3
"""Focused tests for the authenticated Debian package resolver and transactions."""
import contextlib
import hashlib
import importlib.util
import io
import os
import tarfile
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = os.path.join(os.path.dirname(__file__), "..", "tools", "fetch-deps.py")
SPEC = importlib.util.spec_from_file_location("glenv_fetch_deps", MODULE_PATH)
fetch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch)


def ar_member(name, payload):
    header = (
        name.ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) +
        "100644".ljust(8) + str(len(payload)).ljust(10)
    ).encode("ascii") + bytes((96, 10))
    return header + payload + (b"\n" if len(payload) % 2 else b"")


def make_local_deb(path, control, files=()):
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w") as tar:
        data = control.encode("utf-8")
        member = tarfile.TarInfo("control")
        member.size = len(data)
        tar.addfile(member, io.BytesIO(data))
    data_buffer = io.BytesIO()
    with tarfile.open(fileobj=data_buffer, mode="w") as tar:
        for name, contents in files:
            member = tarfile.TarInfo(name)
            member.size = len(contents)
            tar.addfile(member, io.BytesIO(contents))
    archive = b"!<arch>\n"
    archive += ar_member("debian-binary/", b"2.0\n")
    archive += ar_member("control.tar/", tar_buffer.getvalue())
    archive += ar_member("data.tar/", data_buffer.getvalue())
    with open(path, "wb") as stream:
        stream.write(archive)


class ResolverTests(unittest.TestCase):
    def test_debian_version_order(self):
        self.assertLess(fetch.deb_version_cmp("1.0~rc1", "1.0"), 0)
        self.assertGreater(fetch.deb_version_cmp("1:1.0-1", "2.0-9"), 0)
        self.assertGreater(fetch.deb_version_cmp("1.0-2", "1.0-1"), 0)
        self.assertEqual(fetch.deb_version_cmp("1.01", "1.1"), 0)

    def test_dependency_parser_keeps_constraints_and_arch_qualifier(self):
        self.assertEqual(
            fetch.dep_groups("libc6:any (>= 2.34), foo (<< 4) | bar"),
            [[("libc6", ">=", "2.34")], [("foo", "<<", "4"), ("bar", None, None)]],
        )

    def test_resolver_checks_versions_and_virtual_provides(self):
        index = {
            "app": {"Package": "app", "Version": "1", "Depends": "libfoo (>= 2.0), api (= 3)"},
            "libfoo": {"Package": "libfoo", "Version": "2.1"},
            "impl": {"Package": "impl", "Version": "1"},
        }
        packages, missing = fetch.resolve(
            [("app", None, None)], index, {"api": [("impl", "3")]})
        self.assertEqual([pkg["Package"] for pkg in packages], ["app", "libfoo", "impl"])
        self.assertEqual(missing, [])

    def test_resolver_fails_on_missing_versioned_dependency(self):
        index = {
            "app": {"Package": "app", "Version": "1", "Depends": "libfoo (>= 2.0)"},
            "libfoo": {"Package": "libfoo", "Version": "1.9"},
        }
        packages, missing = fetch.resolve([("app", None, None)], index, {})
        self.assertEqual([pkg["Package"] for pkg in packages], ["app"])
        self.assertEqual(missing, ["libfoo (>= 2.0)"])


class UpgradePlanTests(unittest.TestCase):
    def test_upgrade_dry_run_resolves_packages_without_sysroot_mutations(self):
        index = {
            "app": {"Package": "app", "Version": "2.0", "Depends": "libfoo (>= 1.0)"},
            "libfoo": {"Package": "libfoo", "Version": "1.2"},
        }
        history = [{"packages": ["app"]}]
        with tempfile.TemporaryDirectory() as root:
            prefix = os.path.join(root, "prefix")
            sysroot = os.path.join(prefix, "sysroot")
            output = io.StringIO()
            with patch.object(fetch.sys, "argv", ["fetch-deps.py", "upgrade", "--dry-run"]), \
                 patch.object(fetch, "recover_pending_transactions"), \
                 patch.object(fetch, "update_index"), \
                 patch.object(fetch, "_history_entries", return_value=history), \
                 patch.object(fetch, "parse_packages", return_value=(index, {})), \
                 patch.object(fetch, "PREFIX", prefix), \
                 patch.object(fetch, "SYSROOT", sysroot), \
                 contextlib.redirect_stdout(output):
                fetch.main()
            self.assertIn("Upgrade plan: 2 packages", output.getvalue())
            self.assertIn("app 2.0", output.getvalue())
            self.assertIn("libfoo 1.2", output.getvalue())
            self.assertFalse(os.path.exists(prefix))
            self.assertFalse(os.path.exists(sysroot))


class ExtractionAndRollbackTests(unittest.TestCase):
    def test_local_deb_requires_exact_authenticated_package(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "sample.deb")
            make_local_deb(
                path,
                "Package: sample\nVersion: 1.2-3\nArchitecture: amd64\nDepends: libc6 (>= 2.34)\n",
            )
            with open(path, "rb") as stream:
                digest = hashlib.sha256(stream.read()).hexdigest()
            index = {
                "sample": {
                    "Package": "sample",
                    "Version": "1.2-3",
                    "Architecture": "amd64",
                    "SHA256": digest,
                }
            }
            previous_arch = fetch.ARCH
            try:
                fetch.ARCH = "amd64"
                self.assertEqual(fetch.verify_local_deb(path, index)["Package"], "sample")
                index["sample"]["SHA256"] = "0" * 64
                with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
                    fetch.verify_local_deb(path, index)
                index["sample"]["SHA256"] = digest
                index["sample"]["Version"] = "1.2-4"
                with self.assertRaisesRegex(RuntimeError, "authenticated Debian index"):
                    fetch.verify_local_deb(path, index)
            finally:
                fetch.ARCH = previous_arch

    def test_local_deb_is_snapshotted_and_hashed_before_extraction(self):
        with tempfile.TemporaryDirectory() as root:
            source = os.path.join(root, "sample.deb")
            with open(source, "wb") as stream:
                stream.write(b"authenticated archive")
            digest = hashlib.sha256(b"authenticated archive").hexdigest()
            snapshot = fetch.snapshot_local_deb(source, digest, root)
            with open(source, "wb") as stream:
                stream.write(b"replaced after verification")
            with open(snapshot, "rb") as stream:
                self.assertEqual(stream.read(), b"authenticated archive")
            os.unlink(snapshot)
            with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
                fetch.snapshot_local_deb(source, digest, root)

    def test_local_deb_extracts_in_staging_and_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as root:
            safe_deb = os.path.join(root, "safe.deb")
            make_local_deb(
                safe_deb,
                "Package: sample\nVersion: 1\nArchitecture: amd64\n",
                [("usr/bin/sample", b"safe payload")],
            )
            stage = os.path.join(root, "stage")
            fetch.extract(safe_deb, stage)
            with open(os.path.join(stage, "usr", "bin", "sample"), "rb") as stream:
                self.assertEqual(stream.read(), b"safe payload")

            unsafe_deb = os.path.join(root, "unsafe.deb")
            make_local_deb(
                unsafe_deb,
                "Package: sample\nVersion: 1\nArchitecture: amd64\n",
                [("../escaped", b"no")],
            )
            with self.assertRaisesRegex(RuntimeError, "unsafe path"):
                fetch.extract(unsafe_deb, os.path.join(root, "unsafe-stage"))
            self.assertFalse(os.path.exists(os.path.join(root, "escaped")))

    def test_tar_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            archive = os.path.join(root, "payload.tar")
            outside = os.path.join(root, "escaped")
            with tarfile.open(archive, "w") as tar:
                data = b"bad"
                member = tarfile.TarInfo("../escaped")
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
            with self.assertRaisesRegex(RuntimeError, "unsafe path"):
                fetch._safe_extract_tar(archive, os.path.join(root, "stage"))
            self.assertFalse(os.path.exists(outside))

    def test_transaction_can_restore_replaced_and_new_files(self):
        with tempfile.TemporaryDirectory() as root:
            prefix = os.path.join(root, "prefix")
            sysroot = os.path.join(prefix, "sysroot")
            stage = os.path.join(root, "stage")
            txn = os.path.join(prefix, ".pending")
            os.makedirs(os.path.join(sysroot, "usr", "lib"))
            os.makedirs(os.path.join(stage, "usr", "lib"))
            os.makedirs(txn)
            original = os.path.join(sysroot, "usr", "lib", "old.so")
            with open(original, "w", encoding="utf-8") as stream:
                stream.write("before")
            with open(os.path.join(stage, "usr", "lib", "old.so"), "w", encoding="utf-8") as stream:
                stream.write("after")
            with open(os.path.join(stage, "usr", "lib", "new.so"), "w", encoding="utf-8") as stream:
                stream.write("new")

            previous_prefix, previous_sysroot = fetch.PREFIX, fetch.SYSROOT
            try:
                fetch.PREFIX, fetch.SYSROOT = prefix, sysroot
                changes = fetch.merge_staged_tree(stage, sysroot, txn)
                entry = dict(changes, id="test-transaction")
                history = os.path.join(prefix, "history", entry["id"])
                os.makedirs(os.path.dirname(history))
                os.replace(txn, history)
                fetch.rollback_entry(entry)
            finally:
                fetch.PREFIX, fetch.SYSROOT = previous_prefix, previous_sysroot

            with open(original, encoding="utf-8") as stream:
                self.assertEqual(stream.read(), "before")
            self.assertFalse(os.path.exists(os.path.join(sysroot, "usr", "lib", "new.so")))

    def test_rollback_refuses_files_changed_after_install(self):
        with tempfile.TemporaryDirectory() as root:
            prefix = os.path.join(root, "prefix")
            sysroot = os.path.join(prefix, "sysroot")
            stage = os.path.join(root, "stage")
            txn = os.path.join(prefix, ".pending")
            os.makedirs(os.path.join(stage, "usr", "lib"))
            os.makedirs(txn)
            with open(os.path.join(stage, "usr", "lib", "new.so"), "w", encoding="utf-8") as stream:
                stream.write("installed")

            previous_prefix, previous_sysroot = fetch.PREFIX, fetch.SYSROOT
            try:
                fetch.PREFIX, fetch.SYSROOT = prefix, sysroot
                changes = fetch.merge_staged_tree(stage, sysroot, txn)
                with open(os.path.join(sysroot, "usr", "lib", "new.so"), "w", encoding="utf-8") as stream:
                    stream.write("modified")
                with self.assertRaisesRegex(RuntimeError, "changed since transaction"):
                    fetch.rollback_entry(dict(changes, id="test-transaction"), txn)
            finally:
                fetch.PREFIX, fetch.SYSROOT = previous_prefix, previous_sysroot

    def test_pending_transaction_recovery_restores_sysroot(self):
        with tempfile.TemporaryDirectory() as root:
            sysroot = os.path.join(root, "sysroot")
            stage = os.path.join(root, "stage")
            txn = os.path.join(root, "pending")
            os.makedirs(os.path.join(sysroot, "usr", "lib"))
            os.makedirs(os.path.join(stage, "usr", "lib"))
            os.makedirs(txn)
            target = os.path.join(sysroot, "usr", "lib", "libx.so")
            with open(target, "w", encoding="utf-8") as stream:
                stream.write("old")
            with open(os.path.join(stage, "usr", "lib", "libx.so"), "w", encoding="utf-8") as stream:
                stream.write("new")
            fetch.merge_staged_tree(stage, sysroot, txn)
            fetch.recover_pending_transaction(txn, sysroot)
            with open(target, encoding="utf-8") as stream:
                self.assertEqual(stream.read(), "old")


if __name__ == "__main__":
    unittest.main()
