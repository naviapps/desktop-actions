"""Pack both macOS runtimes and exercise the independent NuGet consumers."""

import argparse
import json
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

from sdk_tooling.adapters import git, load, tooling_command
from sdk_tooling.c_headers import prepare_generated
from sdk_tooling.dotnet import subprocess_environment
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.workspaces import temporary_workspace
from sdk_tooling.xcframework import xcframework

from distribution.nuget import (
    WINDOWS_DEPENDENCY,
    check_dependency_version,
    pack_sdk,
    snapshot,
    verify_acceptance,
    verify_snapshot,
    window_management_package,
)

MACOS_RUNTIMES = ("osx-arm64", "osx-x64")


def pack_pair(root, dependency_source, runtimes, work):
    packages = tomllib.loads((root / "Cargo.lock").read_text(encoding="utf-8"))["package"]
    _, revision = window_management_package(packages)
    dependency = work / "window-management"
    snapshot(dependency_source, revision, dependency)
    metadata = ffi_product(dependency)
    check_dependency_version(root, metadata)

    artifacts = load("artifacts")
    handoff = root / ".native-build/windows"
    accepted = None
    if "win-x64" in runtimes:
        accepted = verify_acceptance(handoff, artifacts)
        commit = git(root, "rev-parse", "HEAD^{commit}").decode().strip()
        if accepted.get("source") != commit or accepted.get("windowManagementSource") != revision:
            raise ValueError("Windows native export differs from the locked SDK revisions")
        if accepted.get("nativeAotFixtureExecuted") is not True:
            raise ValueError("Windows native export requires a successful Native AOT fixture")
        shutil.copytree(
            handoff / WINDOWS_DEPENDENCY / "win-x64",
            dependency / ".native-build/windows/win-x64",
            symlinks=True,
        )

    # Each artifact uses the tool revision that produced its native receipt.
    environment = subprocess_environment()
    environment["NUGET_PACKAGES"] = str(work / "restore")
    result = work / "window-package.txt"
    subprocess.run(
        [
            "mise",
            "run",
            "sdk-tooling",
            "--",
            "python",
            "-m",
            "distribution.pack_nuget",
            *(argument for rid in runtimes for argument in ("--runtime", rid)),
            "--result",
            result,
        ],
        cwd=dependency,
        env=environment | {"MISE_TRUSTED_CONFIG_PATHS": str(dependency)},
        check=True,
    )
    verify_snapshot(dependency, revision)
    name = f"NaviApps.WindowManagement.{metadata.version}.nupkg"
    if result.read_text(encoding="utf-8") != name:
        raise ValueError("WindowManagement packer did not return the locked package filename")
    dependency_package = dependency / ".native-build/packages" / name
    prepare_generated(root, env=environment)
    package = pack_sdk(
        xcframework(root),
        load,
        runtimes,
        sources=[dependency_package.parent],
        environment=environment,
    )
    if accepted is not None:
        for archive, native_path in (
            (package, "win-x64/native-build.json"),
            (dependency_package, f"{WINDOWS_DEPENDENCY}/win-x64/native-build.json"),
        ):
            receipt = json.loads(archive.with_suffix(".nupkg.json").read_bytes())
            if receipt["nativeReceipts"]["win-x64"] != accepted["outputs"][native_path]:
                raise ValueError("Packed DLL differs from the accepted Windows native build")
        verify_acceptance(handoff, artifacts, accepted)
    return package, dependency_package, environment


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("window_management_source", type=Path, help="Local repository or mirror")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The macOS NuGet consumers require a macOS host")

    root = Path(__file__).resolve().parents[1]
    with temporary_workspace(None, prefix="desktop-actions-nuget-") as work:
        candidate = work / "desktop-actions"
        snapshot(root, git(root, "rev-parse", "HEAD^{commit}").decode().strip(), candidate)
        package, dependency_package, environment = pack_pair(
            candidate, args.window_management_source.resolve(strict=True), MACOS_RUNTIMES, work
        )
        subprocess.run(
            tooling_command(
                "nuget-consumer", package, "--dependency", dependency_package, root=candidate
            ),
            cwd=candidate,
            env=environment,
            check=True,
        )


if __name__ == "__main__":
    main()
