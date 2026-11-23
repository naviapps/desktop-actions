DOTNET_TEST_FLAGS ?=
SDK_TOOLING ?= mise run sdk-tooling --
SWIFT_STRICT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

.DEFAULT_GOAL := check

.PHONY: check check-source check-distribution build build-release format lint test test-consumer native native-verify test-rust test-c test-installed-c test-dotnet test-docs test-distribution-tools

check: check-source test test-consumer

check-source: lint test-rust

check-distribution: native-verify build-release test-docs test-distribution-tools

build:
	swift build $(SWIFT_STRICT_FLAGS)

build-release:
	swift build -c release $(SWIFT_STRICT_FLAGS)

format:
	$(SDK_TOOLING) quality format --dotnet

lint:
	$(SDK_TOOLING) quality check --dotnet

test:
	swift test $(SWIFT_STRICT_FLAGS)

test-consumer:
	$(SDK_TOOLING) swift-consumer

native:
	$(SDK_TOOLING) native

native-verify:
	$(SDK_TOOLING) native --verify

test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline

test-dotnet:
	$(SDK_TOOLING) binding-consumer dotnet $(DOTNET_TEST_FLAGS)

test-c:
	$(SDK_TOOLING) binding-consumer c

test-installed-c:
	$(SDK_TOOLING) installed-consumers --language c

test-docs:
	$(SDK_TOOLING) docs

test-distribution-tools:
	$(SDK_TOOLING) python -m unittest discover -s distribution/tests -v
