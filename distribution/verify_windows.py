#!/usr/bin/env python3
"""Verify Windows x64 packages and fixtures on an owned Windows worker."""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from sdk_tooling import vm_environment as vm
from sdk_tooling.adapters import git, load, support_inputs
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.windows_delivery import RID, TARGET, X64Acceptance, locked_fetch_args

from distribution.nuget import (
    WINDOW_MANAGEMENT,
    WINDOW_MANAGEMENT_URL,
    check_dependency_version,
    pack_sdk,
    snapshot,
    verify_snapshot,
    window_management_package,
)

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = Path("fixtures/acceptance/windows/host/DesktopActions.WindowsAcceptance.csproj")
DESKTOP_TARGET = "test_owned_input_target"
NUGET_CONFIG = Path("bindings/dotnet/NuGet.Config")
RECEIPT = "acceptance.json"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def dependency_source(metadata, environment):
    package, revision = window_management_package(metadata["packages"])
    if (manifest := vm.source_manifest(environment)) is None:
        return Path(package["manifest_path"]).resolve().parents[2], revision

    if manifest.is_symlink() or not manifest.is_file():
        raise ValueError("The captured source manifest must be a local file")
    entries = [e for e in json.loads(manifest.read_bytes()) if e["repository"] == WINDOW_MANAGEMENT]
    if len(entries) != 1:
        raise ValueError("Expected one captured WindowManagement source")
    entry = entries[0]
    if (
        entry["revision"] != revision
        or entry["url"] != WINDOW_MANAGEMENT_URL
        or not re.fullmatch(r"[0-9]+\.bundle", entry["bundle"])
    ):
        raise ValueError("Captured WindowManagement source differs from the Cargo lock")
    bundle = manifest.parent / entry["bundle"]
    mirror = bundle.with_suffix(".git")
    if (
        bundle.is_symlink()
        or not bundle.is_file()
        or mirror.is_symlink()
        or not mirror.is_dir()
        or sha256(bundle) != entry["sha256"]
        or git(mirror, "rev-parse", "HEAD^{commit}").decode().strip() != revision
    ):
        raise ValueError("Captured WindowManagement bundle or mirror differs from its receipt")
    return mirror, revision


def build_sdk(native, selected, tools, environment, host):
    subprocess.run(
        locked_fetch_args(),
        cwd=native.root,
        env=environment,
        check=True,
    )
    windows = selected("windows")
    directory = windows.build_library(native, environment, tools, "x64", native_host=host)
    verified, receipt = windows.verify_artifact(native, "x64", environment=environment)
    toolchain = {
        "backend": "msvc",
        "host": windows.MSVC_TARGETS[host],
        "target": TARGET,
    }
    if verified != directory or receipt.get("toolchain") != toolchain:
        raise ValueError("Windows x64 artifact differs from the selected host build")
    return directory


def check_c_fixture(native, selected, directory):
    selected("binding_checks").check_c(
        source=native.root / "crates/ffi/tests/c/abi.c",
        include_dirs=(native.ffi / "include",),
        library=directory / (native.library + ".dll"),
        work_parent=native.root / ".native-build",
        argv=["--windows-architecture", "x64"],
    )


def run_managed_fixture(native, selected, dotnet, environment, directory, sources, project, *args):
    runtime = "net10.0-windows" if project == DESKTOP else "net10.0"
    selected("dotnet").build_managed(
        dotnet,
        native.root / project,
        cwd=native.root,
        env=environment,
        nuget_config=native.root / NUGET_CONFIG,
        sources=sources,
        properties={
            "RuntimeIdentifier": RID,
            "UseAppHost": "false",
            "UseSharedCompilation": "false",
        },
        verify_style=True,
    )
    # Use the SDK produced during this run, beside the matching target assembly.
    output = native.root / project.parent / "bin/Release" / runtime / RID
    selected("artifacts").stage_native(
        directory / (native.library + ".dll"), output / (native.library + ".dll")
    )
    if project == DESKTOP:
        target = native.root / "target"
        cargo = [
            "cargo",
            "build",
            "--locked",
            "--offline",
            "--target",
            TARGET,
            "--target-dir",
            target,
        ]
        cargo.extend(
            ["--manifest-path", native.root / "fixtures/acceptance/windows/target-app/Cargo.toml"]
        )
        subprocess.run(cargo, cwd=native.root, env=environment, check=True)
        executable = target / TARGET / "debug" / (DESKTOP_TARGET + ".exe")
        selected("windows").require_pe_machine(executable, "x64")
        selected("artifacts").stage_native(executable, output / executable.name)
    subprocess.run(
        [dotnet, str(output / (project.stem + ".dll")), *map(str, args)],
        cwd=native.root,
        env=environment,
        check=True,
    )


def check_installed_package(
    selected, dotnet, environment, native, name, package, fixture, *depends, native_aot=False
):
    properties = {
        "Nullable": "enable",
        "TreatWarningsAsErrors": "true",
        "UseSharedCompilation": "false",
    }
    optional = {}
    if native_aot:
        properties["DefineConstants"] = "NATIVE_AOT_FIXTURE"
        optional["native_aot"] = True
    selected("nuget").run_isolated_consumer(
        dotnet,
        packages=[package, *depends],
        references={name: native.version},
        source=fixture.read_text(encoding="utf-8"),
        work_parent=native.root / ".native-build/packages",
        env=environment,
        runtime=RID,
        properties=properties,
        **optional,
    )


def verify_acceptance(directory, artifacts, expected=None):
    receipt_path = directory / RECEIPT
    if directory.is_symlink() or receipt_path.is_symlink():
        raise ValueError("Use an ordinary Windows acceptance destination")
    record = json.loads(receipt_path.read_bytes())
    inputs = artifacts.hashes(
        [p for p in artifacts.files(directory) if p != receipt_path], directory
    )
    if (
        record.get("schema") != 1
        or record.get("runtime") != RID
        or record.get("outputs") != inputs
        or (expected is not None and expected != record)
    ):
        raise ValueError("Windows x64 acceptance output differs from its receipt")


def publish_acceptance(stage, destination, artifacts, receipt):
    verify_acceptance(stage, artifacts, receipt)
    with artifacts.build_lock(destination.parent):
        if destination.exists() or destination.is_symlink():
            verify_acceptance(destination, artifacts)
        artifacts.publish(
            stage, destination, lambda: verify_acceptance(destination, artifacts, receipt)
        )


def accept(root, environment, host, tools, dotnet, selected, desktop, *, native_aot=False):
    artifacts = selected("artifacts")
    windows = selected("windows")
    base = root / ".native-build"
    base.mkdir(exist_ok=True)
    if base.is_symlink():
        raise ValueError("The native build directory must not be a symlink")
    artifact_root = vm.artifacts_dir(environment)
    result = (artifact_root or base) / "desktop-actions-win-x64"
    commit = git(root, "rev-parse", "HEAD^{commit}").decode().strip()
    verify_snapshot(root, commit)
    tool_inputs = support_inputs(root)

    with tempfile.TemporaryDirectory(prefix="desktop-x64-", dir=base) as temporary:
        work = Path(temporary)
        parent, child = work / "actions", work / "window"
        snapshot(root, commit, parent)
        env = dict(
            environment,
            NUGET_PACKAGES=str(work / "nuget-cache"),
            RUSTUP_AUTO_INSTALL="0",
            CARGO_INCREMENTAL="0",
        )
        subprocess.run(locked_fetch_args(notice_targets=()), cwd=parent, env=env, check=True)
        metadata = json.loads(
            subprocess.check_output(
                [
                    "cargo",
                    "metadata",
                    "--locked",
                    "--offline",
                    "--format-version",
                    "1",
                    "--filter-platform",
                    TARGET,
                ],
                cwd=parent,
                env=env,
            )
        )
        dependency, dependency_revision = dependency_source(metadata, env)
        snapshot(dependency, dependency_revision, child)
        actions = ffi_product(parent)
        window = ffi_product(child)
        check_dependency_version(parent, window)
        window_binary = build_sdk(window, selected, tools, env, host)
        check_c_fixture(window, selected, window_binary)
        window_package = pack_sdk(window, selected, [RID], environment=env)
        check_installed_package(
            selected,
            dotnet,
            env,
            window,
            "NaviApps.WindowManagement",
            window_package,
            child / "fixtures/consumers/dotnet/Program.cs",
        )
        feed = window_package.parent
        actions_binary = build_sdk(actions, selected, tools, env, host)
        subprocess.run(
            ["cargo", "test", "--workspace", "--locked", "--offline", "--target", TARGET],
            cwd=parent,
            env=env,
            check=True,
        )
        check_c_fixture(actions, selected, actions_binary)
        run_managed_fixture(
            actions,
            selected,
            dotnet,
            env,
            actions_binary,
            (feed,),
            Path("bindings/dotnet/tests/DesktopActions.Tests/DesktopActions.Tests.csproj"),
        )

        result.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="accepted-", dir=result.parent) as staging:
            stage = Path(staging) / result.name
            stage.mkdir()
            if desktop:
                # Use and capture only the separate owned Win32 fixture process.
                desktop_output = stage / "desktop-acceptance"
                try:
                    run_managed_fixture(
                        actions,
                        selected,
                        dotnet,
                        env,
                        actions_binary,
                        (feed,),
                        DESKTOP,
                        desktop_output,
                    )
                except subprocess.CalledProcessError:
                    if desktop_output.is_dir() and artifact_root is not None:
                        diagnostics = Path(
                            tempfile.mkdtemp(
                                prefix="desktop-actions-x64-failure-", dir=result.parent
                            )
                        )
                        for name in ("failure.json", "failure-desktop.png", "capture-error.txt"):
                            source = desktop_output / name
                            if source.is_file() and not source.is_symlink():
                                shutil.copyfile(source, diagnostics / name)
                    raise
            actions_package = pack_sdk(actions, selected, [RID], sources=[feed], environment=env)
            fixtures = [("PackageConsumer.cs", False), ("ReflectionFreeConsumer.cs", native_aot)]
            for fixture, publish_native in fixtures:
                check_installed_package(
                    selected,
                    dotnet,
                    env,
                    actions,
                    "NaviApps.DesktopActions",
                    actions_package,
                    parent / "fixtures/consumers/dotnet" / fixture,
                    window_package,
                    native_aot=publish_native,
                )

            verify_snapshot(root, commit)
            if support_inputs(root) != tool_inputs:
                raise ValueError("The SDK build tools changed during Windows acceptance")
            for label, sdk, source, binary, package in (
                ("sdk", actions, commit, actions_binary, actions_package),
                ("window-dependency", window, dependency_revision, window_binary, window_package),
            ):
                verify_snapshot(sdk.root, source)
                windows.verify_artifact(sdk, "x64", environment=env)
                package_receipt = package.with_suffix(".nupkg.json")
                packed = json.loads(package_receipt.read_bytes())
                if (
                    packed.get("runtimes") != [RID]
                    or packed.get("sha256") != sha256(package)
                    or packed.get("nativeReceipts", {}).get(RID)
                    != sha256(binary / "native-build.json")
                ):
                    raise ValueError(
                        "Windows x64 package differs from its accepted native artifact"
                    )
                shutil.copytree(binary, stage / (label + "-windows") / RID)
                for filename in (package, package_receipt):
                    target = stage / (label + "-packages") / filename.name
                    target.parent.mkdir(exist_ok=True)
                    shutil.copyfile(filename, target)

            receipt = {
                "schema": 1,
                "runtime": RID,
                "target": TARGET,
                "host": host,
                "executionMode": "x64-emulation" if host == "arm64" else "native",
                "desktopFixtureExecuted": desktop,
                "source": commit,
                "windowManagementSource": dependency_revision,
                "toolInputs": tool_inputs,
                "outputs": artifacts.hashes(artifacts.files(stage), stage),
            }
            if native_aot:
                receipt["nativeAotFixtureExecuted"] = True
            artifacts.write_json(stage / RECEIPT, receipt)
            publish_acceptance(stage, result, artifacts, receipt)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--desktop", action="store_true", help="Run the separate-process owned desktop fixture"
    )
    parser.add_argument(
        "--native-aot", action="store_true", help="Publish and run the win-x64 Native AOT consumer"
    )
    args = parser.parse_args(argv)
    if sys.platform != "win32":
        raise SystemExit("An owned Windows worker is required for runtime acceptance")
    worker = X64Acceptance(ROOT)
    accept(
        ROOT,
        worker.env,
        worker.host,
        worker.tools,
        worker.dotnet,
        load,
        args.desktop,
        native_aot=args.native_aot,
    )
    print("Windows x64 SDK package and runtime acceptance passed.")


if __name__ == "__main__":
    main()
