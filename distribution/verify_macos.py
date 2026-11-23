"""Pack both macOS runtimes and exercise the independent NuGet consumers."""

import argparse
import subprocess
import sys
import tomllib
from pathlib import Path

from sdk_tooling.adapters import load, tooling_command
from sdk_tooling.dotnet import subprocess_environment
from sdk_tooling.native_plan import ffi_product
from sdk_tooling.workspaces import temporary_workspace
from sdk_tooling.xcframework import xcframework

from distribution.nuget import (
    check_dependency_version,
    pack_sdk,
    snapshot,
    verify_snapshot,
    window_management_package,
)

MACOS_RUNTIMES = ("osx-arm64", "osx-x64")


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("window_management_source", type=Path, help="Local repository or mirror")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("The macOS NuGet consumers require a macOS host")

    root = Path(__file__).resolve().parents[1]
    packages = tomllib.loads((root / "Cargo.lock").read_text(encoding="utf-8"))["package"]
    _, revision = window_management_package(packages)
    with temporary_workspace(None, prefix="desktop-actions-nuget-") as work:
        dependency = work / "window-management"
        snapshot(args.window_management_source.resolve(strict=True), revision, dependency)
        check_dependency_version(root, ffi_product(dependency))

        # Each artifact must be packed using the tool revision that produced its receipt.
        result = work / "window-package.txt"
        environment = subprocess_environment()
        environment["NUGET_PACKAGES"] = str(work / "restore")
        subprocess.run(
            [
                "mise",
                "run",
                "sdk-tooling",
                "--",
                "python",
                "-m",
                "distribution.pack_nuget",
                "--runtime",
                "osx-arm64",
                "--runtime",
                "osx-x64",
                "--result",
                result,
            ],
            cwd=dependency,
            env=environment | {"MISE_TRUSTED_CONFIG_PATHS": str(dependency)},
            check=True,
        )
        verify_snapshot(dependency, revision)
        name = result.read_text(encoding="utf-8")
        if Path(name).name != name or not name.endswith(".nupkg"):
            raise ValueError("WindowManagement packer did not return a package filename")
        dependency_package = dependency / ".native-build/packages" / name
        package = pack_sdk(
            xcframework(root),
            load,
            MACOS_RUNTIMES,
            sources=[dependency_package.parent],
            environment=environment,
        )
        subprocess.run(
            tooling_command(
                "nuget-consumer", package, "--dependency", dependency_package, root=root
            ),
            cwd=root,
            env=environment,
            check=True,
        )


if __name__ == "__main__":
    main()
