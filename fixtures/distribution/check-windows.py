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
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path
from types import SimpleNamespace

from sdk_tooling.adapters import git, load, support_inputs
from sdk_tooling.native_plan import builder

from fixtures.distribution.sdk_packages import pack_sdk

ROOT = Path(__file__).resolve().parents[2]
TARGET = "x86_64-pc-windows-msvc"
RID = "win-x64"
REPOSITORY = "naviapps/window-management"
URL = f"https://github.com/{REPOSITORY}.git"
SOURCE = re.compile(rf"git\+{re.escape(URL)}\?rev=([a-f0-9]{{40}})#\1")
DESKTOP = Path("bindings/dotnet/tests/DesktopActions.NativeTests/DesktopActions.NativeTests.csproj")
DESKTOP_TARGET = "test_owned_input_target"
NUGET_CONFIG = Path("bindings/dotnet/NuGet.Config")
RECEIPT = "acceptance.json"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def snapshot(source, revision, destination):
    """Detach exact Git objects in a private build directory."""
    try:
        actual = git(source, "rev-parse", revision + "^{commit}").decode().strip()
    except RuntimeError as error:
        raise ValueError("The SDK source differs from its immutable revision") from error
    if actual != revision:
        raise ValueError("The SDK source differs from its immutable revision")
    git(
        None,
        "clone",
        "--no-local",
        "--no-checkout",
        "--config",
        "core.autocrlf=false",
        "--config",
        "core.longpaths=true",
        "--",
        str(source),
        str(destination),
    )
    git(destination, "checkout", "--detach", revision)
    verify_snapshot(destination, revision)


def verify_snapshot(root, revision):
    if (
        git(root, "rev-parse", "HEAD^{commit}").decode().strip() != revision
        or git(root, "status", "--porcelain=v1", "--untracked-files=all").strip()
    ):
        raise ValueError("The SDK checkout differs from its accepted revision")


def dependency_source(metadata, environment):
    packages = [p for p in metadata["packages"] if p["name"] == "window-management"]
    if len(packages) != 1 or not (match := SOURCE.fullmatch(packages[0].get("source") or "")):
        raise ValueError("Exactly one immutable WindowManagement dependency is required")
    revision = match[1]
    if not (manifest := environment.get("NAVI_CI_SOURCES")):
        return Path(packages[0]["manifest_path"]).resolve().parents[2], revision

    manifest = Path(manifest)
    if not manifest.is_absolute() or manifest.is_symlink() or not manifest.is_file():
        raise ValueError("The captured source manifest must be a local file")
    entries = [e for e in json.loads(manifest.read_bytes()) if e["repository"] == REPOSITORY]
    if len(entries) != 1:
        raise ValueError("Expected one captured WindowManagement source")
    entry = entries[0]
    if (
        entry["revision"] != revision
        or entry["url"] != URL
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


def check_dependency_version(root, dependency):
    project = root / "bindings/dotnet/src/NaviApps.DesktopActions/NaviApps.DesktopActions.csproj"
    tree = ET.parse(project)
    requirements = [
        ref.get("Version")
        for ref in tree.findall(".//PackageReference")
        if ref.get("Include") == "NaviApps.WindowManagement"
    ]
    if requirements != [f"[{dependency.version}]"]:
        raise ValueError("Managed WindowManagement version differs from the locked Rust SDK")


def build_sdk(native, selected, tools, environment, host):
    subprocess.run(
        [
            "cargo",
            "fetch",
            "--locked",
            "--target",
            TARGET,
            "--target",
            "aarch64-apple-darwin",
            "--target",
            "x86_64-apple-darwin",
        ],
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
    selected("consumers").check_c(
        source=native.root / "crates/ffi/tests/c/abi.c",
        include_dirs=(native.ffi / "include",),
        library=directory / (native.library + ".dll"),
        work_parent=native.root / ".native-build",
        argv=["--windows-architecture", "x64"],
    )


def run_managed_fixture(native, selected, dotnet, environment, directory, sources, project, *args):
    bindings = selected("bindings")
    runtime = "net10.0-windows" if project == DESKTOP else "net10.0"
    bindings.build_managed(
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
    bindings.stage_native(directory / (native.library + ".dll"), output / (native.library + ".dll"))
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
        cargo.extend(["--manifest-path", native.root / "fixtures/windows-target/Cargo.toml"])
        subprocess.run(cargo, cwd=native.root, env=environment, check=True)
        executable = target / TARGET / "debug" / (DESKTOP_TARGET + ".exe")
        selected("windows").require_pe_machine(executable, "x64")
        bindings.stage_native(executable, output / executable.name)
    subprocess.run(
        [dotnet, str(output / (project.stem + ".dll")), *map(str, args)],
        cwd=native.root,
        env=environment,
        check=True,
    )


def check_installed_package(
    selected, dotnet, environment, native, name, package, fixture, *depends
):
    selected("bindings").run_isolated_consumer(
        dotnet,
        packages=[package, *depends],
        references={name: native.version},
        source=fixture.read_text(encoding="utf-8"),
        work_parent=native.root / ".native-build/packages",
        env=environment,
        runtime=RID,
        properties={
            "Nullable": "enable",
            "TreatWarningsAsErrors": "true",
            "UseSharedCompilation": "false",
        },
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


def accept(root, environment, host, tools, dotnet, selected, desktop):
    artifacts = selected("artifacts")
    windows = selected("windows")
    sdk_tools = selected("native")
    cargo = selected("cargo")

    class WindowsSdk(sdk_tools.NativeBuilder):
        def retain_notices(self, env=None):
            cargo.runtime_notices(self.root, env)
            cargo.CargoDependencies(
                self.root, self.notice_packages, (*sdk_tools.DARWIN_TARGETS, TARGET), env
            ).retain_notices()

    base = root / ".native-build"
    base.mkdir(exist_ok=True)
    if base.is_symlink():
        raise ValueError("The native build directory must not be a symlink")
    if (artifacts_path := environment.get("NAVI_CI_ARTIFACTS")) and not Path(
        artifacts_path
    ).is_absolute():
        raise ValueError("The worker artifact root must be absolute")
    result = Path(artifacts_path or base) / "desktop-actions-win-x64"
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
        subprocess.run(
            ["cargo", "fetch", "--locked", "--target", TARGET], cwd=parent, env=env, check=True
        )
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
        actions = builder(parent, tooling=lambda _: SimpleNamespace(NativeBuilder=WindowsSdk))
        window = WindowsSdk(child, symbol_prefix="window_management_", minimum_macos="26.0")
        check_dependency_version(parent, window)
        window_binary = build_sdk(window, selected, tools, env, host)
        check_c_fixture(window, selected, window_binary)
        window_package = pack_sdk(window, selected, ["--runtime", RID], env)
        check_installed_package(
            selected,
            dotnet,
            env,
            window,
            "NaviApps.WindowManagement",
            window_package,
            child / "bindings/dotnet/tests/PackageConsumer/Program.cs",
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
                    if desktop_output.is_dir() and artifacts_path:
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
            actions_package = pack_sdk(
                actions, selected, ["--runtime", RID, "--package-source", str(feed)], env
            )
            for fixture in ("PackageConsumer", "PackageReflectionFreeConsumer"):
                check_installed_package(
                    selected,
                    dotnet,
                    env,
                    actions,
                    "NaviApps.DesktopActions",
                    actions_package,
                    parent / "bindings/dotnet/tests" / fixture / "Program.cs",
                    window_package,
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
            artifacts.write_json(stage / RECEIPT, receipt)
            publish_acceptance(stage, result, artifacts, receipt)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--desktop", action="store_true", help="Run the separate-process owned desktop fixture"
    )
    args = parser.parse_args(argv)
    if sys.platform != "win32":
        raise SystemExit("An owned Windows worker is required for runtime acceptance")
    windows = load("windows")
    host = windows.host_architecture()
    env, tools, dotnet = windows.native_environment(host, target_architecture="x64")
    expected = tomllib.loads((ROOT / "mise.toml").read_text())["tools"]["dotnet"]
    if (
        subprocess.check_output([dotnet, "--version"], env=env, cwd=ROOT, text=True).strip()
        != expected
    ):
        raise ValueError("Use the pinned x64 .NET SDK from mise.toml")
    accept(ROOT, env, host, tools, dotnet, load, args.desktop)
    print("Windows x64 SDK package and runtime acceptance passed.")


if __name__ == "__main__":
    main()
