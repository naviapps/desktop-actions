"""Windows x64 packaging inputs and native fixture selection."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, call, patch

from sdk_tooling.adapters import load

from distribution import nuget, verify_macos
from distribution import verify_windows as windows_sdk


class LockedDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        self.git(self.source, "init", "-q")
        self.contract = self.source / "Cargo.toml"
        self.commit("first")
        self.revision = self.git(self.source, "rev-parse", "HEAD")
        self.commit("newer")
        self.newer_revision = self.git(self.source, "rev-parse", "HEAD")
        self.git(self.source, "checkout", "-q", "--detach", self.revision)
        self.bundle = self.root / "0.bundle"
        self.git(self.source, "bundle", "create", str(self.bundle), "HEAD", "--all")
        self.mirror = self.bundle.with_suffix(".git")
        self.git(self.source, "clone", "-q", "--mirror", str(self.bundle), str(self.mirror))
        self.entry = {
            "repository": nuget.WINDOW_MANAGEMENT,
            "url": nuget.WINDOW_MANAGEMENT_URL,
            "revision": self.revision,
            "bundle": self.bundle.name,
            "sha256": windows_sdk.sha256(self.bundle),
        }
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps([self.entry]), encoding="utf-8")
        self.environment = {"VM_RUNNER_SOURCE_MANIFEST": str(self.manifest)}
        self.source_uri = f"git+{nuget.WINDOW_MANAGEMENT_URL}?rev={self.revision}#{self.revision}"
        self.metadata = {
            "packages": [
                {
                    "name": "window-management",
                    "manifest_path": str(self.source / "crates/core/Cargo.toml"),
                    "source": self.source_uri,
                }
            ],
        }

    @staticmethod
    def git(root, *arguments):
        return subprocess.check_output(
            [
                "git",
                "-C",
                str(root),
                "-c",
                "commit.gpgsign=false",
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                *arguments,
            ],
            text=True,
        ).strip()

    def commit(self, content):
        self.contract.write_text(content, encoding="utf-8")
        self.git(self.source, "add", "Cargo.toml")
        self.git(self.source, "commit", "-qm", content)

    def test_job_build_does_not_use_the_working_copy_or_newer_ref(self):
        self.contract.write_text("uncommitted local edit", encoding="utf-8")
        mirror, revision = windows_sdk.dependency_source(self.metadata, self.environment)
        self.assertEqual((mirror, revision), (self.mirror, self.revision))
        checkout = self.root / "detached"
        nuget.snapshot(mirror, revision, checkout)
        self.assertEqual((checkout / "Cargo.toml").read_text(encoding="utf-8"), "first")
        self.assertEqual(self.contract.read_text(encoding="utf-8"), "uncommitted local edit")
        (checkout / "Cargo.toml").write_text("altered", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "differs from its accepted revision"):
            nuget.verify_snapshot(checkout, revision)

    def test_bundle_bytes_must_match_capture(self):
        self.bundle.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "bundle or mirror differs"):
            windows_sdk.dependency_source(self.metadata, self.environment)

    def test_captured_head_must_match_cargo_revision(self):
        self.git(self.mirror, "update-ref", "HEAD", self.newer_revision)
        with self.assertRaisesRegex(ValueError, "bundle or mirror differs"):
            windows_sdk.dependency_source(self.metadata, self.environment)

    def test_lock_cannot_be_replaced_by_workspace_or_mismatched_source(self):
        for bad in (
            None,
            f"git+{nuget.WINDOW_MANAGEMENT_URL}?rev={self.revision}#{self.newer_revision}",
        ):
            self.metadata["packages"][0]["source"] = bad
            with self.assertRaisesRegex(ValueError, "one immutable WindowManagement"):
                windows_sdk.dependency_source(self.metadata, self.environment)

    def test_local_source_path_must_still_resolve_to_the_locked_commit(self):
        source, revision = windows_sdk.dependency_source(self.metadata, {})
        self.assertEqual(source, self.source)
        self.assertEqual(revision, self.revision)
        with self.assertRaisesRegex(ValueError, "differs from its immutable revision"):
            nuget.snapshot(source, "1" * 40, self.root / "invalid")

    def test_managed_package_version_is_bound_to_rust_dependency(self):
        project = (
            self.root / "bindings/dotnet/src/NaviApps.DesktopActions/NaviApps.DesktopActions.csproj"
        )
        project.parent.mkdir(parents=True)
        project.write_text(
            '<Project><ItemGroup><PackageReference Include="NaviApps.WindowManagement" '
            'Version="[0.1.0]" /></ItemGroup></Project>',
            encoding="utf-8",
        )
        nuget.check_dependency_version(self.root, SimpleNamespace(version="0.1.0"))
        with self.assertRaisesRegex(ValueError, "version differs from the locked Rust SDK"):
            nuget.check_dependency_version(self.root, SimpleNamespace(version="0.2.0"))

    def test_combined_pack_requires_both_locked_sources_and_accepted_native_aot(self):
        (self.source / "Cargo.lock").write_text(
            f'[[package]]\nname = "window-management"\nsource = "{self.source_uri}"\n',
            encoding="utf-8",
        )
        handoff = self.source / ".native-build/windows"
        handoff.mkdir(parents=True)
        receipt = {
            "schema": 1,
            "runtime": "win-x64",
            "source": self.revision,
            "windowManagementSource": self.revision,
            "nativeAotFixtureExecuted": True,
            "outputs": {},
        }
        for changed, value, message in (
            ("source", self.newer_revision, "locked SDK revisions"),
            ("windowManagementSource", self.newer_revision, "locked SDK revisions"),
            ("nativeAotFixtureExecuted", False, "successful Native AOT fixture"),
        ):
            with (
                self.subTest(changed=changed),
                tempfile.TemporaryDirectory() as work,
                patch.object(verify_macos, "ffi_product"),
                patch.object(verify_macos, "check_dependency_version"),
            ):
                load("artifacts").write_json(
                    handoff / nuget.WINDOWS_RECEIPT, receipt | {changed: value}
                )
                with self.assertRaisesRegex(ValueError, message):
                    verify_macos.pack_pair(
                        self.source,
                        self.source,
                        (*verify_macos.MACOS_RUNTIMES, "win-x64"),
                        Path(work),
                    )


class NativeFixtureTests(unittest.TestCase):
    def test_window_management_uses_its_own_pinned_build_and_acceptance_tools(self):
        actions, window = Mock(), Mock()
        selected = Mock()
        window_plan = Mock()
        window_plan.ffi_product.return_value = window
        window_selected = Mock(return_value=window_plan)
        binary, package = Mock(), Mock()
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(windows_sdk, "git", return_value=b"source"),
            patch.object(windows_sdk, "verify_snapshot"),
            patch.object(windows_sdk, "snapshot"),
            patch.object(windows_sdk, "support_inputs", return_value={}),
            patch.object(windows_sdk.subprocess, "run"),
            patch.object(windows_sdk.subprocess, "check_output", return_value=b"{}"),
            patch.object(windows_sdk, "dependency_source", return_value=("mirror", "source")),
            patch.object(windows_sdk, "ffi_product", return_value=actions),
            patch.object(windows_sdk, "pinned_tooling", return_value=window_selected) as pin,
            patch.object(windows_sdk, "check_dependency_version"),
            patch.object(
                windows_sdk, "build_sdk", side_effect=[binary, OSError("stop at primary build")]
            ) as build,
            patch.object(windows_sdk, "check_c_fixture") as check_c,
            patch.object(windows_sdk, "pack_sdk", return_value=package) as pack,
            patch.object(windows_sdk, "check_installed_package") as check_package,
        ):
            with self.assertRaisesRegex(OSError, "stop at primary build"):
                windows_sdk.accept(Path(temporary), {}, "x64", "tools", "dotnet", selected, False)

        child = pin.call_args.args[0]
        window_selected.assert_called_once_with("native_plan")
        window_plan.ffi_product.assert_called_once_with(child)
        self.assertEqual(
            [item.args[:2] for item in build.call_args_list],
            [(window, window_selected), (actions, selected)],
        )
        check_c.assert_called_once_with(window, window_selected, binary)
        self.assertEqual(pack.call_args.args, (window, window_selected, [windows_sdk.RID]))
        self.assertEqual(check_package.call_args.args[0], window_selected)

    def test_disposable_windows_build_disables_incremental_compilation(self):
        environment = {"CARGO_INCREMENTAL": "1", "CARGO_NET_OFFLINE": "true"}
        selected = {
            "artifacts": Mock(),
            "windows": Mock(),
            "ffi": SimpleNamespace(FfiProduct=object),
            "cargo": Mock(),
        }.__getitem__
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(windows_sdk, "git", return_value=b"source"),
            patch.object(windows_sdk, "verify_snapshot"),
            patch.object(windows_sdk, "snapshot"),
            patch.object(windows_sdk, "support_inputs", return_value={}),
            patch.object(
                windows_sdk.subprocess, "run", side_effect=OSError("stop at fetch")
            ) as run,
        ):
            with self.assertRaisesRegex(OSError, "stop at fetch"):
                windows_sdk.accept(
                    Path(temporary),
                    environment,
                    "arm64",
                    "tools",
                    "dotnet",
                    selected,
                    False,
                )
        self.assertEqual(run.call_args.kwargs["env"]["CARGO_INCREMENTAL"], "0")
        self.assertEqual(run.call_args.kwargs["env"]["CARGO_NET_OFFLINE"], "true")
        self.assertEqual(environment["CARGO_INCREMENTAL"], "1")

    def test_desktop_build_stages_the_locked_x64_rust_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            native = SimpleNamespace(root=root, library="desktop_actions")
            dotnet = Mock()
            artifacts = Mock()
            windows = Mock()
            selected = {"dotnet": dotnet, "artifacts": artifacts, "windows": windows}.__getitem__
            with patch.object(windows_sdk.subprocess, "run") as run:
                windows_sdk.run_managed_fixture(
                    native,
                    selected,
                    "dotnet",
                    {},
                    root / "accepted",
                    (root / "feed",),
                    windows_sdk.DESKTOP,
                    root / "result",
                )
            properties = dotnet.build_managed.call_args.kwargs["properties"]
            self.assertEqual(properties["RuntimeIdentifier"], "win-x64")
            self.assertEqual(properties["UseAppHost"], "false")
            output = root / windows_sdk.DESKTOP.parent / "bin/Release/net10.0-windows/win-x64"
            target = root / "target/x86_64-pc-windows-msvc/debug/test_owned_input_target.exe"
            windows.require_pe_machine.assert_called_once_with(target, "x64")
            self.assertEqual(
                artifacts.stage_native.call_args_list,
                [
                    call(root / "accepted/desktop_actions.dll", output / "desktop_actions.dll"),
                    call(target, output / target.name),
                ],
            )
            cargo = [
                "cargo",
                "build",
                "--locked",
                "--offline",
                "--target",
                "x86_64-pc-windows-msvc",
            ]
            cargo.extend(["--target-dir", root / "target", "--manifest-path"])
            cargo.append(root / "fixtures/acceptance/windows/target-app/Cargo.toml")
            self.assertEqual(run.call_args_list[0].args[0], cargo)
            self.assertEqual(
                run.call_args.args[0],
                [
                    "dotnet",
                    str(output / "DesktopActions.WindowsAcceptance.dll"),
                    str(root / "result"),
                ],
            )

    def test_windows_build_verifies_the_selected_target_toolchain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            native = SimpleNamespace(root=root)
            windows = Mock(MSVC_TARGETS={"arm64": "aarch64-pc-windows-msvc"})
            windows.build_library.return_value = root
            windows.verify_artifact.return_value = (
                root,
                {
                    "toolchain": {
                        "backend": "msvc",
                        "host": "aarch64-pc-windows-msvc",
                        "target": "x86_64-pc-windows-msvc",
                    }
                },
            )
            with (
                patch.object(windows_sdk.subprocess, "run") as run,
                patch.object(windows_sdk, "prepare_generated") as prepare,
            ):
                windows_sdk.build_sdk(native, lambda _: windows, "tools", {}, "arm64")
                self.assertIn("x86_64-pc-windows-msvc", run.call_args.args[0])
                self.assertNotIn("aarch64-pc-windows-msvc", run.call_args.args[0])
            prepare.assert_called_once_with(root, env={})
            windows.build_library.assert_called_once_with(
                native, {}, "tools", "x64", native_host="arm64"
            )

    def test_receipt_rejects_a_changed_published_pair(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "pair.nupkg"
            package.write_bytes(b"accepted")
            artifacts = SimpleNamespace(
                files=lambda p: sorted(x for x in p.iterdir() if x.is_file()),
                hashes=lambda files, base: {
                    x.relative_to(base).as_posix(): windows_sdk.sha256(x) for x in files
                },
            )
            receipt = {
                "schema": 1,
                "runtime": "win-x64",
                "outputs": artifacts.hashes([package], root),
            }
            (root / windows_sdk.RECEIPT).write_text(json.dumps(receipt), encoding="utf-8")
            windows_sdk.verify_acceptance(root, artifacts, receipt)
            package.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "output differs from its receipt"):
                windows_sdk.verify_acceptance(root, artifacts, receipt)


class AcceptancePublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.destination = self.root / "published"
        self.artifacts = load("artifacts")

    def stage(self, name, package_bytes):
        stage = self.root / name / "package-pair"
        stage.mkdir(parents=True)
        (stage / "pair.nupkg").write_bytes(package_bytes)
        receipt = {
            "schema": 1,
            "runtime": "win-x64",
            "outputs": self.artifacts.hashes(self.artifacts.files(stage), stage),
        }
        self.artifacts.write_json(stage / windows_sdk.RECEIPT, receipt)
        return stage, receipt

    def test_publisher_verifies_the_moved_receipt(self):
        stage, receipt = self.stage("first", b"first candidate")
        windows_sdk.publish_acceptance(stage, self.destination, self.artifacts, receipt)
        self.assertFalse(stage.exists())
        windows_sdk.verify_acceptance(self.destination, self.artifacts, receipt)
        self.assertEqual((self.destination / "pair.nupkg").read_bytes(), b"first candidate")

    def test_invalid_moved_pair_restores_the_previous_verified_pair(self):
        first, old_receipt = self.stage("first", b"first candidate")
        windows_sdk.publish_acceptance(first, self.destination, self.artifacts, old_receipt)
        stage, new_receipt = self.stage("next", b"second candidate")
        verify = windows_sdk.verify_acceptance

        def tamper_after_move(directory, artifacts, expected=None):
            if directory == self.destination and expected == new_receipt:
                self.assertFalse(stage.exists())
                (directory / "pair.nupkg").write_bytes(b"changed after publication")
            return verify(directory, artifacts, expected)

        with patch.object(windows_sdk, "verify_acceptance", side_effect=tamper_after_move):
            with self.assertRaisesRegex(ValueError, "output differs from its receipt"):
                windows_sdk.publish_acceptance(stage, self.destination, self.artifacts, new_receipt)

        windows_sdk.verify_acceptance(self.destination, self.artifacts, old_receipt)
        self.assertEqual((self.destination / "pair.nupkg").read_bytes(), b"first candidate")


if __name__ == "__main__":
    unittest.main()
