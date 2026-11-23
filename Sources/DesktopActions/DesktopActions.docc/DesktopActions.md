# ``DesktopActions``

Describe desktop actions, inspect native plans and permission requirements, and serialize action payloads without
running live system integrations.

## Overview

`DesktopActions` projects the shared Rust model into Swift. Use it when a host app needs to store,
decode, and inspect actions before deciding whether to execute them.

The core target includes:

- `ActionDescriptor`, `ActionInputForm`, `ActionTextInputKind` and `ActionTextInputEvaluation` for Rust-owned input forms and pure draft evaluation
- `ActionRequest`, `ActionKind`, and `ActionCategory` for supported actions and action-kind metadata
- `ActionInput`, `ActionInputShape`, `ActionInputDescriptor`, and
  `ActionInputParameter` for host-supplied values and input requirements
- `ActionKindCapabilities` and `ActionRetryBehavior` for conservative host-policy metadata
- `ActionPlatform` and ``ActionKind/supportedPlatforms`` for Rust-derived adapter availability
- `ActionCodec` for versioned JSON action envelopes
- `ActionResultCodec` for strict original-byte execution-report JSON
- `ActionPlan` and `ActionPreflight` for inspecting instructions, permission requirements and hints
- `ActionRunner` for host-configured deadlines and bounded worker lifetimes
- `ActionResult`, `ActionError`, `ActionAttempt`, and `ActionExecutionReport` for execution
  reporting

Windowing actions carry `WindowPlacementRequest` and `WindowMoveRequest` values from
the separate `WindowManagement` module. Import that module when constructing those
payloads; its Rust core owns their normalization.

## Responsibility Boundary

The Rust core owns the action catalog, canonical identifiers, input descriptors,
capability metadata, JSON envelopes, strict action/input normalization, execution plans,
permission metadata, result validation/normalization, fallback progression and result reduction.
Reusable window request values and geometry
belong to the separate WindowManagement Rust core. The Swift facade supplies Codable
projections and scheduling for explicit host callbacks.

DesktopActions does not request permissions, post events, run commands, execute
AppleScript, open URLs, control windows, collect analytics, transmit data, or
persist action history. Those live integrations are provided by
`DesktopActionsMacOS` or the host app.

ActionRequest identifiers are the canonical serialization names for the current action catalog. Use
``ActionKind/identifier`` and `ActionCodec` payloads for persistence, IPC, and tool bindings
instead of relying on enum case names as external protocol strings.

Use `ActionKind` when building a picker or command catalog before input is available:

```swift
import DesktopActions

let kind = ActionKind.openURL
let identifier = kind.identifier
let inputDescriptor = kind.inputDescriptor
let inputShape = inputDescriptor.shape
let parameterName = inputDescriptor.parameter?.name
let exampleInput = inputDescriptor.exampleInput
let requiresInput = inputDescriptor.requiresInput
let capabilities = kind.capabilities
let supportedOnWindows = kind.supportedPlatforms.contains(.windows)
let permissionHints = ActionPreflight.permissionHints(forKind: kind)
```

When hosts create custom input metadata, `ActionInputParameter` returns `nil`
for blank labels or invalid example input, and `ActionInputDescriptor`
returns `nil` when the parameter is missing, unnecessary, or does not match the
descriptor shape. Both types delegate validation to the Rust metadata codec used
by the catalog boundary.

Use capabilities as conservative host-policy hints for focused-window
availability, interactive selection, destructive actions, and retry behavior.
Platform support describes an adapter implementation for the input form. It does
not establish valid caller input, installed targets, permission or effect success.

Create an `ActionRequest` once the host has the required input:

```swift
import DesktopActions

if let action = ActionKind.openURL.makeAction(input: .string("https://example.com")) {
  // Store or execute the action.
}
```

Decoded action envelopes, action payloads, standalone `ActionInput` payloads, input metadata,
capability metadata, permission sets, and execution result payloads reject unknown top-level fields
so stored data matches the documented contract.

Live execution reports `ActionExecutionReport` values with ordered `ActionAttempt` records,
`ActionResult` summaries, and `ActionError` diagnostics. Windowing actions use explicit
`WindowPlacementRequest` and `WindowMoveRequest` payloads instead of duplicate fixed-placement
catalog cases.

``ActionRequest/showWindowOverview`` opens Mission Control on macOS and Task View on Windows.
The macOS primary step launches `com.apple.exposelauncher` without Automation; its ordered
Control-Up fallback requires Accessibility. ``ActionRequest/switchToNextVirtualDesktop`` and
``ActionRequest/switchToPreviousVirtualDesktop`` switch existing desktops (Spaces on macOS).
``ActionRequest/missionControlAppExpose`` remains a macOS-only vendor operation.

``ActionRequest/quitFrontmostApplication`` requests application-wide graceful termination
on macOS and is unsupported on Windows. ``ActionRequest/closeForegroundWindow`` requests
an ordinary close of one captured foreground window on both platforms. A close can show
a save prompt or be refused; acceptance does not confirm closure or saved data. There is
no process-termination or keyboard fallback, and hosts must not retry after focus changes.

Saved legacy Mission Control identifiers and Windows application-quit requests require
host migration before decoding. See the
[saved-data migration table](https://github.com/naviapps/desktop-actions/blob/main/README.md#saved-data-migrations)
for replacement identifiers and platform-sensitive handling; the SDK exposes no legacy aliases.

## Keyboard input

Shortcuts describe physical US-ANSI positions using USB HID usages, rather than Unicode
text or native numeric codes. Meta means Command on macOS and the Windows key on Windows;
Control stays Control. Rust accepts F1–F24, but the macOS ANSI adapter rejects unmapped
positions. Windows supports F1–F24 but has no Fn plan, including `fn+f11`; a custom plan
containing an unsupported shortcut is rejected as a whole. Return accepts `return`,
`enter`, bare `↩` (U+21A9) and `↩︎` (U+21A9 U+FE0E).

Dedicated editing actions resolve the current macOS layout; explicit shortcut actions
retain physical positions. Windows Select All and Find use Ctrl+A and Ctrl+F through
its virtual-key route; the target application decides how to handle Find. Consumer
controls use Rust's separate `SystemKey` mapping: macOS NX events and Windows media
virtual keys. Unavailable brightness mappings are explicit. Constructing an event does
not prove that audio or display hardware handles it.

Hosts can validate shortcut input with
``ActionPreflight/isValidKeyboardShortcut(_:)`` before saving or importing it.
The single-argument overload uses the macOS ANSI mapping. Pass an explicit platform
to inspect another adapter's key vocabulary. Validation and execution share the
Rust physical-key parser. Parsing has no live effects and does not rewrite
persisted action strings.

## Topics

### Actions

- ``ActionRequest``
- ``ActionKind``
- ``ActionCategory``
- ``ActionKindCapabilities``
- ``ActionRetryBehavior``
- ``ActionInput``
- ``ActionInputShape``
- ``ActionInputDescriptor``
- ``ActionInputParameter``

### Preflight

- ``ActionPreflight``
- ``ActionPlan``
- ``ActionStep``
- ``ActionMethod``
- ``ActionKeyStroke``
- ``ActionModifiers``
- ``WindowingExecution``
- ``ActionPermission``
- ``ActionPermissionHint``
- ``ActionPermissionReason``
- ``ActionPermissionSet``

Swift `ActionRequest.plan(for:)` and .NET `ActionRequest.Plan` expose the same Rust plan for
an explicit platform. Swift `ActionStep.method` and .NET `ActionPlanStep.Instruction`
project the instructions into typed values, including shared window request types.
The .NET catalog, text evaluation and text or input-free request coding use
generated JSON metadata. Typed window values use the WindowManagement package codecs.
Plans, steps and permission hints compare by value. Instruction order and fallback
roles participate in comparison, and a screen-capture instruction owns its ordered
argument values. Text compares by its exact UTF-8 spelling so distinct paths and
names stay distinct in sets and dictionary keys.
Empty steps mean no platform plan. Invalid input becomes a
failure instruction before native lookup. Windows plans have empty macOS privacy
requirements, and native key codes belong to their plan's platform. The
single-argument `ActionPreflight.isExecutable` uses the macOS adapter. Pass a platform
to validate its plan without querying permissions or discovering targets.

```swift
import DesktopActions

let windows = ActionRequest.lockScreen.plan(for: .windows)
let instruction = windows.steps.first?.method
let canPlan = windows.isExecutable
```

### Results

- ``ActionResult``
- ``ActionExecutionReport``
- ``ActionAttempt``
- ``ActionError``
- ``ActionErrorCode``
- ``ActionSkipReason``

The .NET result codecs use generated JSON metadata. Result construction, decoding
and the runner's failure reporting work when `System.Text.Json` reflection is disabled.

### Previewing an Action Kind

Use `ActionPreflight.inspectKind(_:on:)` to inspect a kind's availability and
privacy requirements for the selected platform before collecting input.
.NET offers the same information through `ActionCatalog.InspectKind`.
Plan the actual request to check its input and inspect its instructions.

### Bounded Execution

`ActionRunner` applies host-supplied capacity and deadlines around an explicit async
operation. A worker waits for its cancellation handle to be registered before it
can run the operation. The Rust pool arbitrates completion, cancellation and timeout
exactly once. The .NET timer rounds each scheduler wait up to a whole millisecond
and uses the original Rust deadline to arbitrate delivery. The runner signals
worker cancellation before delivering a cancellation or timeout result.
Cancellation handlers may finish after delivery. Cancelled or
timed-out workers keep capacity until they return. Native effects already in progress
cannot be undone by cancelling the caller.

Completion checks the deadline even if timer scheduling is delayed, so a late result
cannot become success. Interactive timeout exemptions are an explicit host choice.
The C reducer rejects duplicate or out-of-order step results without advancing state.

- ``ActionRunner``
- ``ActionRunResult``
- ``ActionRunner/ConfigurationError``
- ``ActionSequenceReport``
- ``ActionSequenceStatus``
- ``ActionSequenceFailureBehavior``

`ActionRunner.runSequence` (and .NET `ActionRunner.RunSequenceAsync`) delivers requests in order using the same bounded
runner as individual requests. The host explicitly chooses whether completed
failures and skipped operations stop the sequence. Cancellation, timeout and
capacity rejection always stop: the native worker may still be acknowledging
cancellation, so a later request must not overlap it. A completed sequence has
delivered every request; inspect `allActionsSucceeded` for effect success. Empty
captured sequences complete successfully without invoking an operation. In .NET,
cancellation before or during deferred enumeration abandons the snapshot and releases
its iterator. An iterator that throws cancellation with the supplied token produces
the cancelled report with zero deliveries. An empty array still completes successfully.
A synchronous iteration step already in progress can finish before the adapter observes
cancellation. If the timeout selector throws cancellation with the supplied token,
the sequence retains earlier results and records cancellation for the issued action.
Rust owns order, continuation and aggregate success. Bindings retain immutable
request and result values.
Hosts retain custom commands, permission guidance, logging and deadline exemptions.

### Coding

- ``ActionCodec``
- ``ActionCodecError``
- ``ActionResultCodec``

Rust trims Unicode whitespace from text inputs and rejects empty or NUL-containing
execution values. Format characters such as U+200B remain part of folder, application
or Shortcut names. Native adapters preserve the normalized value; path expansion and
filesystem checks stay native. Swift `ActionRequest` and `ActionInput` compare/hash
text by exact UTF-8 bytes. Direct enum cases keep raw whitespace in identity, while
`input`, coding and planning apply Rust normalization. .NET `ActionRequest.Equals`
and collection keys compare the canonical action identifier and input retained by Rust.

Version 1 envelopes contain `version` and `action`; actions contain `kind` and, where
required, an untagged `input`. Use `ActionCodec` or .NET `ActionRequest.FromEnvelope`
for untrusted original bytes: Rust rejects duplicate keys, unknown fields/identifiers,
missing required input and explicit nulls before language decoding. Generic Swift
`Decoder` may consume duplicate keys or numeric spelling before nested `Codable`
validation. Codable errors retain the native codec error as their underlying cause;
the byte codec exposes `ActionCodecError` directly. .NET uses `ActionDataException`
with a portable category and optional unsupported version. C views borrow their owner;
copy bytes before `desktop_actions_json_destroy`.

Standalone `ActionInput` values carry `shape` and `value`. Swift's Codable projection
and .NET `ActionInput.FromJson` and `ToJson` share Rust normalization for text,
placement and movement inputs. .NET hosts can create requests with
`ActionRequest.CreateWithInput` and read them through `ActionRequest.TypedInput`.

Swift and .NET input parameter metadata preserve the exact UTF-8 spelling of
normalized labels for equality. Both bindings validate labels, examples, and shape
through Rust. .NET constructors throw `ActionDataException` for invalid metadata.
The resulting metadata is read-only and owns its example JSON.

`ActionResultCodec` and .NET `FromJson` apply the same original-byte boundary to errors,
results, attempts and outcomes. Rust owns compatible error fields, diagnostic defaults,
permission ordering, finite nonnegative durations and final-result consistency. Native
failures remain distinct from macOS privacy denials. Exact float round trips preserve
finite durations and coordinates; Swift `ActionAttempt.durationSeconds` retains the
wire value while its `duration` view rounds to the nearest attosecond.

### Windowing

Import `WindowManagement` for window request values. Their API documentation is
owned by the [WindowManagement package](https://github.com/naviapps/window-management).

On macOS, ``ActionRequest/toggleFocusedWindowFullScreen`` requests the opposite of
the focused window's native full-screen state. It requires Accessibility and takes no input.
An automatic retry may undo the transition or affect a different window.

### Input Presentation

- ``ActionDescriptor``
- ``ActionInputForm``
- ``ActionTextInputKind``
- ``ActionTextInputEvaluation``
- ``ActionTextInputIssue``

Swift `ActionTextInputKind.evaluate`, .NET `ActionTextInput.Evaluate` and C
`desktop_actions_text_input_evaluate` share Rust's pure draft evaluator, including supplied Shortcut
catalogs and directory observations. They leave drafts and saved payloads untouched.
The optional `DesktopActionsSwiftUI` product supplies standard controls and symbols;
hosts retain localized copy, loading state, picker commands and acceptance policy.
