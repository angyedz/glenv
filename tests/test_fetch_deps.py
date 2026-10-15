#!/usr/bin/env python3
"""Focused tests for the authenticated Debian package resolver and transactions."""
import importlib.util
import io
import os
import tempfile
import tarfile
import unittest

MODULE_PATH = os.path.join(os.path.dirname(__file__), "..", "tools", "fetch-deps.py")
SPEC = importlib.util.spec_from_file_location("glenv_fetch_deps", MODULE_PATH)
fetch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetch)


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


class ExtractionAndRollbackTests(unittest.TestCase):
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
