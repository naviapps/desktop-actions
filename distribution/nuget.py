"""Select the managed project and retained files for the SDK package driver."""

import json
import re
import xml.etree.ElementTree as ET

from sdk_tooling.adapters import git

WINDOW_MANAGEMENT = "naviapps/window-management"
WINDOW_MANAGEMENT_URL = f"https://github.com/{WINDOW_MANAGEMENT}.git"
WINDOW_MANAGEMENT_SOURCE = re.compile(
    rf"git\+{re.escape(WINDOW_MANAGEMENT_URL)}\?rev=([a-f0-9]{{40}})#\1"
)
WINDOWS_RECEIPT = "acceptance.json"
WINDOWS_DEPENDENCY = "dependencies/window-management"


def snapshot(source, revision, destination):
    """Detach exact Git objects in a private build directory."""
    if source != WINDOW_MANAGEMENT_URL:
        require_revision(source, revision)
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
    require_revision(destination, revision)
    git(destination, "checkout", "--detach", revision)
    verify_snapshot(destination, revision)


def require_revision(source, revision):
    try:
        actual = git(source, "rev-parse", revision + "^{commit}").decode().strip()
    except RuntimeError as error:
        raise ValueError("The SDK source differs from its immutable revision") from error
    if actual != revision:
        raise ValueError("The SDK source differs from its immutable revision")


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


def verify_acceptance(directory, artifacts, expected=None):
    receipt_path = directory / WINDOWS_RECEIPT
    if directory.is_symlink() or receipt_path.is_symlink():
        raise ValueError("Use an ordinary Windows acceptance destination")
    record = json.loads(receipt_path.read_bytes())
    inputs = artifacts.hashes(
        [p for p in artifacts.files(directory) if p != receipt_path], directory
    )
    if (
        record.get("schema") != 1
        or record.get("runtime") != "win-x64"
        or record.get("outputs") != inputs
        or (expected is not None and expected != record)
    ):
        raise ValueError("Windows x64 acceptance output differs from its receipt")
    return record


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
