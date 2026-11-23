#!/usr/bin/env python3
"""Run this SDK's package fixture through the pinned local-feed consumer driver."""

from pathlib import Path

from _tooling import load


def main():
    root = Path(__file__).resolve().parents[1]
    consumers = load("consumers")
    for fixture in ("PackageConsumer", "PackageReflectionFreeConsumer"):
        consumers.check_nuget(
            package_id="NaviApps.DesktopActions",
            fixture=root / "bindings/dotnet/tests" / fixture / "Program.cs",
            work_parent=root / ".native-build/packages",
        )


if __name__ == "__main__":
    main()
