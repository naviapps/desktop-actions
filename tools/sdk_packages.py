"""Select the managed project and retained files for the SDK package driver."""


def pack_sdk(native, selected, arguments, environment=None):
    root = native.root
    basename = {
        "desktop-actions-ffi": "NaviApps.DesktopActions",
        "window-management-ffi": "NaviApps.WindowManagement",
    }[native.package]
    files = {"LICENSE": root / "LICENSE", "README.md": root / "README.md"}
    files.update(
        {
            path.relative_to(root).as_posix(): path
            for path in selected("artifacts").files(root / "ThirdParty")
            if path.name not in (".DS_Store", "registry-notices.json")
        }
    )
    return selected("bindings").pack_native(
        native,
        project=root / "bindings/dotnet/src" / basename / (basename + ".csproj"),
        version=native.version,
        authors="Navi Apps",
        package_files=files,
        nuget_config=root / "bindings/dotnet/NuGet.Config",
        input_files=(
            [
                root / "tools" / name
                for name in ("pack-dotnet.py", "_tooling.py", "check-windows.py", "sdk_packages.py")
            ]
            if basename == "NaviApps.DesktopActions"
            else []
        ),
        argv=arguments,
        environment=environment,
    )
