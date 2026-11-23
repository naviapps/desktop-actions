#!/usr/bin/env python3
"""Run the .NET fixture against the SDK's native library."""

from _tooling import load
from native import builder


def main():
    native = builder()
    root = native.root
    framework = (
        native.artifact / "macos-arm64_x86_64" / (native.module + ".framework") / native.module
    )

    load("consumers").check_dotnet(
        project=root / "bindings/dotnet/tests/DesktopActions.Tests/DesktopActions.Tests.csproj",
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        framework=framework,
        library_name=native.library,
        windows_root=root / ".native-build/windows",
        work_parent=root / ".native-build/managed",
        cwd=root,
    )


if __name__ == "__main__":
    main()
