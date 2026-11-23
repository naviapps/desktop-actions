#!/usr/bin/env python3
"""Package the verified macOS framework without publishing."""

import argparse

from _tooling import load
from native import builder
from sdk_packages import pack_sdk


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime", choices=("osx-arm64", "osx-x64"), action="append", required=True
    )
    parser.add_argument("--package-source", action="append", default=[])
    options = parser.parse_args()
    arguments = [value for rid in options.runtime for value in ("--runtime", rid)]
    arguments += [
        value for source in options.package_source for value in ("--package-source", source)
    ]
    pack_sdk(builder(), load, arguments)


if __name__ == "__main__":
    main()
