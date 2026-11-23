"""Select the managed project and retained files for the SDK package driver."""

import re
import xml.etree.ElementTree as ET

from sdk_tooling.adapters import git

WINDOW_MANAGEMENT = "naviapps/window-management"
WINDOW_MANAGEMENT_URL = f"https://github.com/{WINDOW_MANAGEMENT}.git"
WINDOW_MANAGEMENT_SOURCE = re.compile(
    rf"git\+{re.escape(WINDOW_MANAGEMENT_URL)}\?rev=([a-f0-9]{{40}})#\1"
)


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


def window_management_package(packages):
    matches = [p for p in packages if p["name"] == "window-management"]
    if len(matches) != 1 or not (
        revision := WINDOW_MANAGEMENT_SOURCE.fullmatch(matches[0].get("source") or "")
    ):
        raise ValueError("Exactly one immutable WindowManagement dependency is required")
    return matches[0], revision[1]


def check_dependency_version(root, dependency):
    project = root / "bindings/dotnet/src/NaviApps.DesktopActions/NaviApps.DesktopActions.csproj"
    requirements = [
        ref.get("Version")
        for ref in ET.parse(project).findall(".//PackageReference")
        if ref.get("Include") == "NaviApps.WindowManagement"
    ]
    if requirements != [f"[{dependency.version}]"]:
        raise ValueError("Managed WindowManagement version differs from the locked Rust SDK")


def pack_sdk(native, selected, runtimes, *, sources=(), environment=None):
    root = native.root
    basename = {
        "desktop-actions-ffi": "NaviApps.DesktopActions",
        "window-management-ffi": "NaviApps.WindowManagement",
    }[native.package]
    inputs = ["mise.toml", "native.toml", "distribution/pack_nuget.py"]
    if basename == "NaviApps.DesktopActions":
        inputs.extend(
            (
                "distribution/nuget.py",
                "distribution/verify_macos.py",
                "distribution/verify_windows.py",
            )
        )
    files = {"LICENSE": root / "LICENSE", "README.md": root / "README.md"}
    files.update(
        {
            path.relative_to(root).as_posix(): path
            for path in selected("artifacts").files(root / "ThirdParty")
            if path.name not in (".DS_Store", "registry-notices.json")
        }
    )
    return selected("nuget").pack_native(
        native,
        project=root / "bindings/dotnet/src" / basename / (basename + ".csproj"),
        package_files=files,
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        input_files=[root / path for path in inputs],
        runtimes=runtimes,
        sources=sources,
        environment=environment,
    )
