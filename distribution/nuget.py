"""Select the managed project and retained files for the SDK package driver."""


def pack_sdk(native, selected, runtimes, *, sources=(), pack_targets=None, environment=None):
    root = native.root
    basename = {
        "desktop-actions-ffi": "NaviApps.DesktopActions",
        "window-management-ffi": "NaviApps.WindowManagement",
    }[native.package]
    pinned_window = basename == "NaviApps.WindowManagement"
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
        input_files=(
            [
                root / path
                for path in (
                    "mise.toml",
                    "distribution/pack_nuget.py",
                    "distribution/verify_windows.py",
                    "distribution/nuget.py",
                )
            ]
            if not pinned_window
            else []
        ),
        runtimes=runtimes,
        sources=sources,
        pack_targets=pack_targets,
        environment=environment,
    )
