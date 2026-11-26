DOTNET_TEST_FLAGS ?=
SDK_TOOLING ?= mise run sdk-tooling --
SWIFT_STRICT_FLAGS := -Xswiftc -warnings-as-errors

.DEFAULT_GOAL := check

.PHONY: check check-source check-distribution build build-release clean format lint test test-consumer native native-verify check-header test-rust test-c test-installed-c test-dotnet test-distribution-tools

check: check-source test test-consumer

check-source: lint check-header test-rust

check-distribution: native-verify build-release test-distribution-tools

build:
	swift build $(SWIFT_STRICT_FLAGS)

build-release:
	swift build -c release $(SWIFT_STRICT_FLAGS)

clean:
	$(SDK_TOOLING) clean .build target .native-build fixtures/consumers/swift/.build \
	  fixtures/acceptance/windows/target-app/target \
	  fixtures/acceptance/windows/host/bin fixtures/acceptance/windows/host/obj \
	  bindings/dotnet/src/NaviApps.DesktopActions/bin bindings/dotnet/src/NaviApps.DesktopActions/obj \
	  bindings/dotnet/tests/DesktopActions.Tests/bin bindings/dotnet/tests/DesktopActions.Tests/obj

format:
	$(SDK_TOOLING) quality format --dotnet

lint:
	$(SDK_TOOLING) quality check --dotnet

test:
	swift test $(SWIFT_STRICT_FLAGS)

test-consumer:
	$(SDK_TOOLING) swift-consumer

native:
	$(SDK_TOOLING) xcframework

native-verify:
	$(SDK_TOOLING) xcframework --verify

check-header:
	$(SDK_TOOLING) c-headers check

test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline

test-dotnet:
	$(SDK_TOOLING) check-binding dotnet $(DOTNET_TEST_FLAGS)

test-c:
	$(SDK_TOOLING) check-binding c

test-installed-c:
	$(SDK_TOOLING) rust-c-consumers --language c

test-distribution-tools:
	$(SDK_TOOLING) python -m unittest discover -s distribution/tests -v
