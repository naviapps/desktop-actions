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
- [Platform boundaries](#platform-boundaries) and [saved-data migrations](#saved-data-migrations)
- [Development and validation](#development-and-validation)
- [Windows execution and acceptance](https://github.com/naviapps/desktop-actions/blob/main/docs/WINDOWS.md)
- Swift API and shared model contracts: [DesktopActions](https://github.com/naviapps/desktop-actions/blob/main/Sources/DesktopActions/DesktopActions.docc/DesktopActions.md),
  [DesktopActionsMacOS](https://github.com/naviapps/desktop-actions/blob/main/Sources/DesktopActionsMacOS/DesktopActionsMacOS.docc/DesktopActionsMacOS.md)
  and [DesktopActionsSwiftUI](https://github.com/naviapps/desktop-actions/blob/main/Sources/DesktopActionsSwiftUI/DesktopActionsSwiftUI.docc/DesktopActionsSwiftUI.md)
- [C header](https://github.com/naviapps/desktop-actions/blob/main/crates/ffi/include/desktop_actions.h) and
  [.NET public API](https://github.com/naviapps/desktop-actions/tree/main/bindings/dotnet/src/NaviApps.DesktopActions)

## Installation

The native ABI is 6. Keep managed packages and native
runtime assets from the same build. Private feeds must retain immutable package
versions; local packing and CI do not publish or replace a feed package.

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

Keep the header and binary from the same SDK revision. A C client needs neither
Rust nor the SDK sources. Copy each `desktop_actions_json_view` result before calling
`desktop_actions_json_destroy` on its owner if the bytes are needed afterward.

### .NET

.NET consumers use `NaviApps.DesktopActions` and its exact
`NaviApps.WindowManagement` dependency from a private/local NuGet feed. The packages
carry their selected native runtimes; consumers need neither Rust nor MSVC.
No package source is added globally. For a .NET 10 client, select the package version
provided by that feed (currently `0.1.0` in this repository):

```sh
dotnet new console --name ActionClient --framework net10.0
dotnet add ActionClient/ActionClient.csproj package NaviApps.DesktopActions \
  --version 0.1.0 --source /path/to/private-feed
```

The selected feed must contain both packages. `WindowsActionExecutor` performs live
effects on Windows only; use `DesktopActionsMacOS` for the default Swift macOS executor.

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

```csharp
using NaviApps.DesktopActions;

var text = new ActionInput.Text("  https://example.com  ");
var open = ActionRequest.CreateWithInput("action.workspace.open-url", text);
var restoredText = ActionInput.FromJson(open.TypedInput!.ToJson());

var action = ActionRequest.Create("action.editing.copy");
var windows = action.Plan(ActionPlatform.Windows);
if (windows.Steps[0].Instruction is ActionMethod.KeyEvent key)
{
    Console.WriteLine(key.VirtualKeyCode);
}
```

.NET `ActionPlanStep.Instruction` provides typed values from the Rust plan.
`ActionPlanStep.Method` exposes the owned JSON for callers that inspect the wire fields.
Catalog parameters expose `TypedExampleInput` for action construction. Swift's
`ActionInput` Codable representation and .NET's `ActionInput.FromJson` and `ToJson`
use the same Rust codec for standalone tagged input. Action requests embed the
untagged input value in the existing v1 envelope.

When reading JSON from disk or the network, pass the original bytes to Rust.
Swift offers `ActionCodec.decode`, `decodeRequest`, `decodeInput` and
`ActionResultCodec`. In .NET use `ActionRequest.FromUtf8Envelope` or the
`FromUtf8Json` methods on requests, inputs, errors, results, attempts and reports.
Invalid UTF-8 and duplicate fields are rejected without changing action text.

Execution errors, results, attempts and reports compare by value in Swift and
through `Equals` and hash collections in .NET. Diagnostic spelling is exact,
reports compare attempts in order, and an absent duration differs from zero.
Run results compare their status and execution report. Sequence reports compare
their status, aggregate success and ordered deliveries.

For live macOS execution and host permission hooks, see the
[macOS API guide](https://github.com/naviapps/desktop-actions/blob/main/Sources/DesktopActionsMacOS/DesktopActionsMacOS.docc/DesktopActionsMacOS.md).
For .NET Windows execution, see the [Windows guide](https://github.com/naviapps/desktop-actions/blob/main/docs/WINDOWS.md).
Managed Windows hosts can opt into captured-foreground execution with
`WindowsActionExecutor.CaptureForegroundTarget` and `ExecuteForTargetAsync`.

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

Use Swift 6.3 or newer with Xcode, macOS 26 or newer, Rust 1.99.1 and .NET 10.
The checks use public SDK Tooling pinned in [`mise.toml`](mise.toml), together
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
shared tool can fetch its pinned revision without private credentials. GitHub Actions
runs the Swift tests and consumer on macOS 26 with Xcode 26.6 and macOS 27 with
Xcode 27.2. Public Windows CI runs the Rust workspace tests on x64.

### Consumer installation checks

The independent clients use injected desktop effects.

| Command                                       | Coverage                                                                                                                                                 |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mise exec -- make test-consumer`             | Swift fixture imports every public product and checks codecs, validation, platform planning and an injected runner with consumer-owned permission hooks. |
| `mise run sdk-tooling -- installed-consumers` | Rust Git client checks placement requests and Accessibility metadata and records the exact WindowManagement revision.                                    |
| `mise exec -- make test-installed-c`          | C client checks the copied framework, public header, notices and the same placement and permission metadata.                                             |

For both Rust/C clients outside CI, supply a complete local WindowManagement mirror
or bundle containing its pinned revision.

```sh
mise run sdk-tooling -- installed-consumers \
  --git-dependency-source naviapps/window-management=/path/to/window-management.bundle
```

Run from a clean committed checkout. Shallow producer checkouts also need a complete
mirror or bundle via `--git-source`. The distribution workflow clones
WindowManagement for the local delivery check. A fresh Cargo cache may fetch public crates.
These checks verify installation from isolated local sources. The
[Windows desktop fixture](docs/WINDOWS.md#windows-ci-and-owned-acceptance)
verifies native effects on an owned worker.

### Distribution verification

Dispatch the detailed macOS and Windows checks in
[`naviapps/sdk-tooling`](https://github.com/naviapps/sdk-tooling) with the full SDK
commit SHA from `main`. [`sdk-distribution.toml`](sdk-distribution.toml) declares
the commands for each platform.

```sh
gh workflow run check-sdk-distribution.yml -R naviapps/sdk-tooling \
  -f sdk=desktop-actions -f "revision=$(git rev-parse HEAD)"
```

For local macOS distribution checks, run `mise exec -- make check-distribution`.
It uses the revision in the `sdk-tooling` task in [`mise.toml`](mise.toml).
[`native.toml`](native.toml) declares the native artifact and is recorded in its
build receipt. For a detailed Swift dependency-graph check, run
`mise run sdk-tooling -- swift-consumer --distribution`.

### Native artifacts and package checks

A clean clone uses the tracked framework. Rebuild it after production Rust/C/input
changes with `mise exec -- make native`; test-only edits do not require a rebuild.
`make check-distribution` verifies that framework and runs the release build,
distribution fixture tests and DocC checks. The Rust tests in `make check` cover the input codec, metadata invariants, and platform plan
matrix. The binding tests exercise typed projections, error mapping, ownership,
and native adapter behavior.
The strict Swift tests compile all library products in debug mode.
Run the C and .NET fixtures separately without rebuilding it:

```sh
mise exec -- make test-c
mise run sdk-tooling -- binding-consumer dotnet --package-source /path/to/private-feed
```

`DOTNET_BIN` selects an existing .NET executable. Follow the
[Windows acceptance guide](docs/WINDOWS.md#windows-ci-and-owned-acceptance)
to build and verify both DesktopActions and its fixed WindowManagement dependency
on an owned Windows worker. The manual macOS package route uses the tracked
framework and tests a fresh local-feed client.

```sh
mise run sdk-tooling -- python fixtures/distribution/pack-dotnet.py --runtime osx-arm64 --runtime osx-x64 --package-source /path/to/private-feed
mise run sdk-tooling -- binding-consumer nuget .native-build/packages/NaviApps.DesktopActions.0.1.0.nupkg --dependency /path/to/NaviApps.WindowManagement.0.1.0.nupkg
```

The package fixture checks codecs, platform planning, shared window requests/runtime and bounded execution
without posting input. Keep `ThirdParty/`, Rust provenance, framework
`Resources/ThirdPartyNotices.txt` and NuGet runtime notices intact.
`mise exec -- make native-verify` checks the framework against its build receipt.
[Windows acceptance](docs/WINDOWS.md#windows-ci-and-owned-acceptance)
records OS effects separately from compilation and installation.

### Documentation and static checks

Run `mise exec -- make lint` to check source and workflows or
`mise exec -- make format` to format source files.
For documentation changes, `mise exec -- make test-docs` builds symbol graphs and
verifies all three DocC catalogs with warnings as errors; it may resolve and compile
Swift dependencies. Check Markdown alone with
`mise exec -- dprint check README.md AGENTS.md 'docs/*.md'`.

## License

This SDK is licensed under the [MIT License](LICENSE). Keep the
[third-party notices](ThirdParty/) with redistributed artifacts.
