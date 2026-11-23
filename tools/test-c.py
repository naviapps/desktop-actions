#!/usr/bin/env python3
"""Compile and run the C ABI fixture against the SDK's native library."""

from _tooling import load
from native import builder


def main():
    native = builder()
    root = native.root
    framework = (
        native.artifact / "macos-arm64_x86_64" / (native.module + ".framework") / native.module
    )

    load("consumers").check_c(
        source=root / "crates/ffi/tests/c/abi.c",
        include_dirs=(native.ffi / "include",),
        library=framework,
        work_parent=root / ".native-build",
    )
    print(root.name + " C ABI fixture passed.")


if __name__ == "__main__":
    main()
