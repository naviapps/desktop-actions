#!/usr/bin/env python3
"""Pack the verified native runtimes without publishing."""

import argparse
from pathlib import Path

from sdk_tooling.adapters import load
from sdk_tooling.workspaces import temporary_workspace

from distribution.nuget import WINDOW_MANAGEMENT_URL
from distribution.verify_macos import MACOS_RUNTIMES, pack_pair

RUNTIMES = (*MACOS_RUNTIMES, "win-x64")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=RUNTIMES, action="append", required=True)
    parser.add_argument("--window-management-source", type=Path)
    parser.add_argument(
        "--result",
        type=Path,
        required=True,
        help="Write the combined primary and dependency package filenames",
    )
    options = parser.parse_args()
    if tuple(sorted(options.runtime)) != RUNTIMES:
        parser.error("Select each of the three runtimes exactly once")

    dependency_source = options.window_management_source or WINDOW_MANAGEMENT_URL
    if isinstance(dependency_source, Path):
        dependency_source = dependency_source.resolve(strict=True)
    root = Path(__file__).resolve().parents[1]
    with temporary_workspace(None, prefix="desktop-actions-nuget-") as work:
        package, dependency, _ = pack_pair(root, dependency_source, options.runtime, work)
        artifacts = load("artifacts")
        with artifacts.build_lock(package.parent):
            for source in (dependency, dependency.with_suffix(".nupkg.json")):
                artifacts.stage_file(source, package.parent / source.name)
            with options.result.open("x", encoding="utf-8") as result:
                result.write(f"{package.name}\n{dependency.name}\n")


if __name__ == "__main__":
    main()
