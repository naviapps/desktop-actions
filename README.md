# DesktopActions

Desktop action SDK with shared Rust semantics and Swift, C and .NET interfaces.
The macOS adapter uses AppKit and Accessibility. The Rust Windows adapter performs
native effects through the same plans and result reducer. Catalog presence alone
does not mean that an operation is available on a particular OS. Native runtime
coverage belongs to its recorded source, platform and test conditions.

## Ownership

- `crates/core`: the authoritative catalog, action codec, input normalization,
  physical shortcut parser, execution plans, permission metadata, result codecs/reduction and bounded execution state.
- `crates/ffi`: owned C JSON results and thread-safe execution handles.
- `Sources`: Swift values, optional SwiftUI inputs and the native macOS adapter.
- `crates/windows`: the native Windows adapter.
- `bindings/dotnet`: managed values and native interop.
- `Artifacts`: SwiftPM native frameworks and their build receipt.
- `fixtures`: standalone SDK consumers and SDK-specific distribution checks.

Window geometry, placement requests and display selection belong to the separate
[WindowManagement SDK](https://github.com/naviapps/window-management). Application discovery,
launch and process operations belong to
[DesktopApplications](https://github.com/naviapps/desktop-applications). DesktopActions composes
those resources into actions. Hosts own persistence, permission prompts, product limits,
gesture matching and product UI.

## Contents

- [Installation](#installation) and [inspect an action](#inspect-an-action)
- [Platform boundaries](#platform-boundaries), [saved action JSON](#saved-action-json)
  and [saved-data migrations](#saved-data-migrations)
- [Development and validation](#development-and-validation)
- [Windows execution and acceptance](https://github.com/naviapps/desktop-actions/blob/main/docs/WINDOWS.md)
- Swift guides for [the shared action model](https://github.com/naviapps/desktop-actions/blob/main/docs/swift.md),
  [macOS execution](https://github.com/naviapps/desktop-actions/blob/main/docs/swift-macos.md)
  and [SwiftUI controls](https://github.com/naviapps/desktop-actions/blob/main/docs/swiftui.md)
- [C header bundled in the framework](https://github.com/naviapps/desktop-actions/blob/main/Artifacts/CDesktopActions.xcframework/macos-arm64_x86_64/CDesktopActions.framework/Versions/A/Headers/desktop_actions.h) and
  [.NET guide](bindings/dotnet/README.md)

## Installation

### Swift

Swift consumers add `https://github.com/naviapps/desktop-actions.git`, pin a full
commit ID and select `DesktopActions`, `DesktopActionsMacOS` or the optional `DesktopActionsSwiftUI`. The tracked native
framework needs no Rust build on the consumer's machine. Consumers that use window
request types directly also declare the `WindowManagement` product from the pinned
`window-management` dependency. The macOS adapter also consumes the pinned
`DesktopApplications` / `DesktopApplicationsMacOS` products from `desktop-applications`.

For example, this complete client manifest selects all three public products.
Replace the revision placeholder with the published 40-character commit ID of
the SDK build you intend to install. Put client source in
`Sources/ActionClient/main.swift`.

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "ActionClient",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(
      url: "https://github.com/naviapps/desktop-actions.git",
      revision: "FULL_40_CHARACTER_PUBLISHED_COMMIT_ID"),
  ],
  targets: [
    .executableTarget(
      name: "ActionClient",
      dependencies: [
        .product(name: "DesktopActions", package: "desktop-actions"),
        .product(name: "DesktopActionsMacOS", package: "desktop-actions"),
        .product(name: "DesktopActionsSwiftUI", package: "desktop-actions"),
      ]),
  ]
)
```

The selected SDK revision's [Package.swift](https://github.com/naviapps/desktop-actions/blob/main/Package.swift) owns its immutable
`desktop-applications` and `window-management` revisions and its public
`swift-subprocess` requirement. Retain the client's `Package.resolved` to record
the selected public dependency revisions. SwiftPM resolves these dependencies
without the SDK's developer tooling or package-path overrides.

### Rust

The public `desktop-actions` Rust crate requires Rust 1.99 or later and the target
platform linker. It performs deterministic planning without linking a native
desktop adapter. Select a full
published DesktopActions commit and copy its exact `window-management` revision
from that commit's `Cargo.toml` into the second placeholder:

```toml
[dependencies]
desktop-actions = { git = "https://github.com/naviapps/desktop-actions.git", rev = "<FULL_PUBLISHED_COMMIT_SHA>" }
window-management = { git = "https://github.com/naviapps/window-management.git", rev = "<WINDOW_MANAGEMENT_COMMIT_FROM_SELECTED_SDK>" }
```

Declare `window-management` directly if the client constructs window request
values. Use the exact revision in the selected DesktopActions commit's
`Cargo.toml` so both crates use the same Rust types.

### C

For C on macOS 26 or later, install `CDesktopActions.framework` from
`Artifacts/CDesktopActions.xcframework/macos-arm64_x86_64`, preserving the
framework symlinks and retained notices. Use the Clang from the macOS developer
tools and include `<CDesktopActions/desktop_actions.h>`. Set `framework_dir` to
the absolute directory containing the installed framework:

```sh
xcrun clang -std=c17 -mmacosx-version-min=26.0 consumer.c \
  -F "$framework_dir" -framework CDesktopActions \
  -Xlinker -rpath -Xlinker "$framework_dir" -o consumer
```

The C ABI is 6. Keep the header and binary from the same SDK revision. A C client
needs neither Rust nor the SDK sources. Copy each `desktop_actions_json_view` result before calling
`desktop_actions_json_destroy` on its owner if the bytes are needed afterward.

### .NET

Use [NaviApps.DesktopActions](bindings/dotnet/README.md#install) and its exact
`NaviApps.WindowManagement` dependency.

## Inspect an action

After installing the Swift package, construct and validate a request without native effects:

```swift
import DesktopActions

let action = ActionRequest.openURL("https://example.com")
let supportedOnMacOS = action.kind.supportedPlatforms.contains(.macOS)
let windowsPlan = action.plan(for: .windows)
let isExecutable = windowsPlan.isExecutable
let permissionHints = ActionPreflight.permissionHints(for: action)
let saved = try ActionCodec.encode(action)
let restored = try ActionCodec.decode(saved)
```

Swift `ActionRequest.plan(for:)` and .NET `ActionRequest.Plan` inspect either adapter,
including its ordered instructions, fallback roles and permission metadata. Preflight
does not query permissions, discover installed targets or execute the request.
Swift `ActionPreflight.inspectKind(_:on:)` and .NET `ActionCatalog.InspectKind`
preview availability and privacy requirements before the host collects input.
Plan an actual request to validate its input and inspect its instructions.

For the C# example and managed projections, see
[Inspect an action in .NET](bindings/dotnet/README.md#inspect-an-action).

For live macOS execution and host permission hooks, see the
[macOS API guide](https://github.com/naviapps/desktop-actions/blob/main/docs/swift-macos.md).
For live Windows execution, see the [Windows guide](docs/WINDOWS.md).

## Platform boundaries

Swift window-action callers import `WindowManagement` for request values; .NET uses
`ActionRequest.PlaceWindow` / `MoveWindow` with that SDK's request classes.
`ActionKind.supportedPlatforms` / .NET `ActionDescriptor.SupportedPlatforms` derive
adapter availability from Rust plans; they do not prove valid input, permission,
installed targets or successful effects.

| Action                          | Boundary                                                                                                                                                                            |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `closeForegroundWindow`         | Requests close of one captured window on macOS and Windows, allowing save prompts or refusal. No keyboard or application-termination fallback. Unsafe to retry after focus changes. |
| `minimizeFocusedWindow`         | Requests minimization of one captured window. Unsafe to retry because success transfers focus.                                                                                      |
| `toggleFocusedWindowFullScreen` | macOS Accessibility only, with no keyboard fallback. Retrying can reverse the transition or affect a different window.                                                              |
| `launchApplication`             | macOS accepts a name, bundle identifier or `.app` path; an explicit path targets only that installation, allowing reuse of that copy. Windows requires an absolute `.exe` path.     |

The default macOS executor resolves explicit `.main` placement to the system's primary
display, independently of the display containing the key window.

## Saved action JSON

Use the stable catalog identifier, such as `ActionKind.identifier` in Swift, for
`kind` in storage and IPC. The version 1 envelope contains `version` and
`action`. A bare action contains `kind` and, when required, an untagged
`input`. The input shape must match the selected kind. Omit `input` for
input-free actions. Standalone inputs use the tagged `shape` and `value` form.

Pass original UTF-8 bytes from disk or the network to the SDK codec before
language-level parsing. Rust rejects malformed UTF-8, duplicate fields, unknown
fields or action identifiers, unsupported versions, and missing, null, or
mismatched action input.

- In Swift, pass `Data` to `ActionCodec.decode` for an envelope, `decodeRequest`
  for a bare action, or `decodeInput` for standalone input. Use
  `ActionResultCodec` for errors, results, attempts and execution reports.
- In .NET, pass `ReadOnlySpan<byte>` to `ActionRequest.FromUtf8Envelope` for
  an envelope. Use `FromUtf8Json` on `ActionRequest`, `ActionInput`,
  `ActionError`, `ActionResult`, `ActionAttempt` or `ActionExecutionReport`
  for the corresponding bare payload.

The codec trims Unicode whitespace from text and rejects text that becomes
empty. Format characters such as U+200B keep their spelling. Planning rejects
NUL characters in folder, application and Shortcut inputs. Path expansion and
filesystem checks belong to the native adapters. Rust rejects unknown fields in
input and capability metadata and permission sets. It validates labels, example
values and each input descriptor's shape. Parameter metadata keeps the exact
UTF-8 spelling of its normalized labels for equality and owns its example JSON.

Rust validates result fields and orders permissions. Constructing an error with
an empty diagnostic message uses the default for its error code. A report's
final result must match its last attempt. Native failure codes remain distinct
from macOS privacy denials. Round trips preserve
finite duration and window-coordinate values exactly. Attempt duration is
optional, finite and nonnegative when present. Errors, results, attempts and
reports compare by value in Swift and .NET, including exact diagnostic spelling,
attempt order, and the distinction between absent and zero durations. Run results
compare their status and execution report. Sequence reports compare their status,
aggregate success and ordered deliveries.

In .NET, codec failures throw `ActionDataException` with a portable `Code` and
the unsupported `Version` when applicable. For Swift's nested Codable behavior,
see the [Swift coding guide](https://github.com/naviapps/desktop-actions/blob/main/docs/swift.md#coding).

## Saved-data migrations

Hosts must migrate these saved identifiers before using the current strict codec:

| Previous identifier                            | Current identifier                                 |
| ---------------------------------------------- | -------------------------------------------------- |
| `action.system.mission-control`                | `action.system.show-window-overview`               |
| `action.system.mission-control-next-space`     | `action.system.switch-to-next-virtual-desktop`     |
| `action.system.mission-control-previous-space` | `action.system.switch-to-previous-virtual-desktop` |

Their input-free action shape and v1 envelope are unchanged. The old identifiers
are rejected; no aliases are installed. Preserve every other envelope field and
host draft while changing `kind`. A saved Windows `action.frontmost-application.quit`
previously requested one-window close: migrate it to `action.window.close` to retain
that behavior. Keep macOS `action.frontmost-application.quit` as application-wide quit.
If the saved platform is unknown, retain the original request for host resolution
rather than silently changing an application quit into a window close.
The input-free `action.window.close` / `closeForegroundWindow` is available on
macOS and Windows and is unsafe to retry because focus can change after a close.

## Development and validation

Use Xcode with Swift 6.3 or newer on macOS 26 or newer, the
[pinned Rust toolchain](rust-toolchain.toml), and .NET 10.
The checks use public SDK Tooling pinned in [`mise.toml`](https://github.com/naviapps/desktop-actions/blob/main/mise.toml), together
with SDK-owned fixtures and validation settings. Run from the repository root.

```sh
mise trust mise.toml
mise install
mise exec -- cargo fetch --locked
mise exec -- make check
```

`mise install` may download tools. Select Xcode with `DEVELOPER_DIR` when needed. For local host development, set
`DESKTOP_APPLICATIONS_PACKAGE_PATH` and `WINDOW_MANAGEMENT_PACKAGE_PATH` to the
same checkouts declared by that host. Without overrides SwiftPM uses immutable pins.
Keep the Rust and Swift revisions aligned for DesktopApplications and WindowManagement.

`make check` runs the source checks, Rust workspace tests and Clippy, strict
Swift tests and the standalone Swift consumer. The first invocation of the
shared tool can fetch its pinned revision without private credentials. The
[SDK workflow](.github/workflows/check.yml) runs the Swift tests and consumer on
macOS 26 and 27 and the Rust workspace tests on Windows x64.

### Consumer installation checks

The independent clients use injected desktop effects.

| Command                                    | Coverage                                                                                                                                                 |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mise exec -- make test-consumer`          | Swift fixture imports every public product and checks codecs, validation, platform planning and an injected runner with consumer-owned permission hooks. |
| `mise run sdk-tooling -- rust-c-consumers` | Rust Git client checks placement requests and Accessibility metadata and records the exact WindowManagement revision.                                    |
| `mise exec -- make test-installed-c`       | C client checks the copied framework, public header, notices and the same placement and permission metadata.                                             |

For the Rust consumer outside CI, supply a complete local WindowManagement mirror
or bundle containing its pinned revision. The C-only target uses the tracked
framework.

```sh
mise run sdk-tooling -- rust-c-consumers \
  --git-dependency-source naviapps/window-management=/path/to/window-management.bundle
```

Run from a clean committed checkout. Shallow producer checkouts also need a complete
mirror or bundle via `--git-source`. The distribution workflow clones
WindowManagement for the local delivery check. A fresh Cargo cache may fetch public crates.
These checks verify installation from isolated local sources. The
[Windows desktop fixture](https://github.com/naviapps/desktop-actions/blob/main/docs/WINDOWS.md#windows-ci-and-owned-acceptance)
verifies native effects on an owned worker.

### Distribution verification

Dispatch the detailed macOS and Windows checks in
[`naviapps/sdk-tooling`](https://github.com/naviapps/sdk-tooling) with the full SDK
commit SHA from `main`. The `[distribution]` section of
[`sdk-tooling.toml`](https://github.com/naviapps/desktop-actions/blob/main/sdk-tooling.toml)
declares the commands for each platform.

```sh
gh workflow run check-sdk-distribution.yml -R naviapps/sdk-tooling \
  -f sdk=desktop-actions -f "revision=$(git rev-parse HEAD)" -f windows-on-arm=true
```

The Windows job verifies both x64 builds and runs the Native AOT consumer.
The macOS job combines the accepted DLLs with both macOS architectures in each
package. The workflow verifies the same primary package and exact dependency
on macOS ARM64, macOS x64 through Rosetta and Windows x64, including emulation
on Windows 11 ARM64 when requested. Use the
[.NET installation guide](bindings/dotnet/README.md#install) to consume the packages.

For local macOS distribution checks, run `mise exec -- make check-distribution`.
For a detailed Swift dependency-graph check, run
`mise run sdk-tooling -- swift-consumer --distribution`.

Independent package consumers live in [`fixtures/consumers/`](https://github.com/naviapps/desktop-actions/tree/main/fixtures/consumers).
The [owned Windows acceptance projects](https://github.com/naviapps/desktop-actions/tree/main/fixtures/acceptance/windows) exercise
live desktop behavior. [`distribution/`](https://github.com/naviapps/desktop-actions/tree/main/distribution) contains the SDK's
packaging and validation entry points.

### Native artifacts and package checks

A clean clone uses the tracked framework. Rebuild after changes to the Rust FFI
or other native build inputs with `mise exec -- make native`. The `[native]`
section of [`sdk-tooling.toml`](sdk-tooling.toml) declares the artifact.
The build generates the C header and module map in `crates/ffi` and bundles them
in the framework. `make native-verify` checks the framework against the generated
declarations and its build receipt.
`make check-distribution` verifies the framework and runs the release build and
distribution tool tests. The Rust tests in `make check` cover the input codec,
metadata invariants and platform plan matrix. The binding tests exercise typed
projections, error mapping, ownership and native adapter behavior.
The strict Swift tests compile all library products in debug mode.
Run the C and .NET fixtures separately without rebuilding it:

```sh
mise exec -- make test-c
mise run sdk-tooling -- check-binding dotnet --package-source /path/to/private-feed
```

`DOTNET_BIN` selects an existing .NET executable. Follow the
[Windows acceptance guide](https://github.com/naviapps/desktop-actions/blob/main/docs/WINDOWS.md#windows-ci-and-owned-acceptance)
to build and verify both DesktopActions and its fixed WindowManagement dependency
on an owned Windows worker. For a local macOS-only package check, pass a
WindowManagement repository containing the revision
in DesktopActions' `Cargo.lock`. It can be your existing checkout.

```sh
mise run sdk-tooling -- python -m distribution.verify_macos /path/to/window-management
```

The verifier uses temporary snapshots of the current DesktopActions commit and
the exact WindowManagement dependency. Each SDK uses the Tooling revision
recorded with its own framework. The check audits both macOS RIDs, then runs the
consumers with the host .NET architecture and a fresh package cache. It
discards the macOS-only candidates. To check an existing package pair:

```sh
mise run sdk-tooling -- nuget-consumer /path/to/NaviApps.DesktopActions.0.1.0.nupkg --dependency /path/to/NaviApps.WindowManagement.0.1.0.nupkg
```

The package fixture checks codecs, platform planning, shared window requests/runtime and bounded execution
without posting input. Keep `ThirdParty/`, Rust provenance, framework
`Resources/ThirdPartyNotices.txt` and NuGet runtime notices intact.

### Documentation and static checks

Run `mise exec -- make lint` to check source and workflows or
`mise exec -- make format` to format source files.
Check Markdown with
`mise exec -- dprint check README.md AGENTS.md 'docs/*.md'`.

## License

This SDK is licensed under the [MIT License](LICENSE). Keep the
[third-party notices](ThirdParty/) with redistributed artifacts.
