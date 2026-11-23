#!/usr/bin/env python3
"""Package the verified macOS framework without publishing."""

import argparse

from sdk_tooling.adapters import load
from sdk_tooling.xcframework import xcframework

from distribution.nuget import pack_sdk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime", choices=("osx-arm64", "osx-x64"), action="append", required=True
    )
    parser.add_argument("--package-source", action="append", default=[])
    options = parser.parse_args()
    pack_sdk(xcframework(), load, options.runtime, sources=options.package_source)


if __name__ == "__main__":
    main()
