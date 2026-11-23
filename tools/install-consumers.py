#!/usr/bin/env python3
"""Run the SDK's independent Git Rust and installed macOS C fixtures."""

import tomllib
from pathlib import Path

from _tooling import load

ROOT = Path(__file__).resolve().parent.parent


def main(argv=None):
    workspace = tomllib.loads((ROOT / "Cargo.toml").read_text(encoding="utf-8"))["workspace"]
    load("installed_consumers").check_installed(
        root=ROOT,
        git_url="https://github.com/naviapps/desktop-actions.git",
        rust_packages=("desktop-actions",),
        rust_git_dependencies={"window-management": workspace["dependencies"]["window-management"]},
        framework=(
            "Artifacts/CDesktopActions.xcframework/macos-arm64_x86_64/CDesktopActions.framework"
        ),
        header="desktop_actions.h",
        argv=argv,
    )


if __name__ == "__main__":
    main()
