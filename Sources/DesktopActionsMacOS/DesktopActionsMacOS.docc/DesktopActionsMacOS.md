# ``DesktopActionsMacOS``

Execute DesktopActions actions using live macOS integrations.

## Overview

`DesktopActionsMacOS` provides the package's default live executor for host apps. It translates
`DesktopActions` actions into AppKit, Core Graphics, AppleScript, Shortcuts URL, screen capture, and
WindowManagementMacOS operations.

The main entry point is `ActionExecutor`:

```swift
import DesktopActionsMacOS
import DesktopActions

let executor = ActionExecutor()
let outcome = try await executor.execute(.copy)
```

Host apps should provide an `ActionExecutorConfiguration` when they need app-specific permission
hooks, recovery UI, or logging. The package does not own user onboarding, shortcut registration,
persistence, analytics, or telemetry.
The default Accessibility hook reads the current macOS trust state without prompting.
Use ``ActionExecutorConfiguration/LogLevel`` to decide which executor diagnostics are forwarded.

Execution throws `CancellationError` when the calling task is cancelled. Existing
callers must use `try await` and handle cancellation separately from a returned
`ActionExecutionReport`. Cancellation is checked before permission hooks and subsequent
operations or fallback attempts. Owned screen-capture and AppleScript child processes
are stopped and reaped before cancellation returns. Host apps own deadlines; the
executor adds no implicit timeout. Cancellation cannot undo completed OS effects.

Hosts running an action from an approval that can become stale can pass a `beforeStep`
check to ``ActionExecutor/execute(_:beforeStep:)``. The executor checks approval before
calling an Accessibility or Automation readiness hook or starting System Events. It checks
again before dispatching the step, including for a step with no permissions or a failed
prerequisite. If Screen Recording access is denied, the executor checks approval before
calling the host's recovery hook and again after it returns. The check may run multiple
times per step. Returning false throws `CancellationError` and abandons the plan before
further dispatch or fallback. It does not pin OS focus or roll back an operation already started.

Application discovery checks cancellation after each lookup before starting the
next lookup or opening a resolved application. Live workspace opens, application
launches, hide and terminate commands check again on the MainActor before the
native request. If cancellation occurs while waiting for discovery or that actor,
the adapter stops before issuing the next request. Cancellation also takes
precedence over logging or recording an ordinary workspace/application failure;
an OS request already in progress may still complete.

For a bundle-identifier launch, each registered copy must still declare the
requested identifier. A missing or invalid copy can lead to another registered
copy before an OS request; a rejected request ends the launch. A linked `Info.plist` is
accepted when its target is a regular file.

Foreground-window close, focused-window minimization, full-screen toggling, placement and
display moves also check cancellation on the MainActor before native work.
Cancellation throws before ordinary failure
logging or a fallback attempt; it cannot undo a window operation already started.

When a step requires System Events, the adapter starts it without activation
after any required Accessibility check. It then calls the host's Automation
readiness hook with the target running. Failure or cancellation during
preparation prevents the hook and script from running.

Notification Center uses the Accessibility and Automation script path. If the
required permissions are denied or the script reports failure, the executor
returns that failure without posting an ordinary F8 key event.

Default executors in the same process share in-flight System Events discovery and
launch. Cancelling a caller ends its wait without cancelling other callers. When the last caller leaves, the
coordinator cancels further polling and abandons that attempt; a late callback
cannot finish a newer attempt. An already accepted OS launch cannot be withdrawn.

Use `DesktopActions.ActionRunner` when the host needs bounded concurrency or a deadline.
Supply the policy and operation explicitly:

```swift
let runner = try ActionRunner(maximumConcurrentExecutions: 4, timeout: .seconds(15))
let delivery = await runner.run(.copy) { action in
  try await executor.execute(action)
}
```

The Rust run reducer chooses each step and records its result. AppKit supplies OS
effects and invokes host permission callbacks after copying native data. A timed-out
worker retains its capacity reservation until its native operation returns.

Keyboard and system key events are posted as uninterrupted down/up pairs among
this SDK's concurrent macOS actions. Cancellation while waiting for another
pair prevents posting; an already-posted down event is always followed by its up
event. This ordering applies to the SDK's posts, not input from other sources.

Dedicated `copy`, `cut`, `paste`, `undo`, `redo`, `selectAll`, and `findInApp` actions
resolve Command-C, Command-X, Command-V, Command-Z, Command-Shift-Z, Command-A,
and Command-F on the current effective keyboard layout after Accessibility and
host admission. The logical letter and canonical stroke come from the same Rust
editing action definition.
The executor checks the selected input source, layout and hardware type again
immediately before sending the pair. A missing, ambiguous or changed mapping
returns an unsupported-action failure and posts nothing. Explicit keyboard
shortcuts stay physical. Rust plan inspection continues to report the canonical
physical instruction. The executor does not switch input sources or guarantee
how a target app handles a shortcut.

Child-process lifecycle and bounded I/O use Swift Subprocess. AppleScript uses an
owned `osascript` process with bounded stderr instead of a detached `NSAppleScript`.
Native error numbers are preserved without raw script or error text. No child
output or command arguments are added to logs or diagnostics.
Screen-capture plans pass `-p` to use the system's configured destination and
capture settings instead of requiring a caller-supplied file path.

`closeForegroundWindow` calls `AXWindowController.requestClose` on the captured
Accessibility window and presses only its native close button. Missing close support
returns a failure without sending a keyboard shortcut or terminating the application.
The application retains save prompts and may refuse the request. `quitFrontmostApplication`
uses DesktopApplications for an application-wide graceful termination request instead.

`toggleFocusedWindowFullScreen` reads and changes the captured window's native
full-screen state through WindowManagementMacOS. An absent focused window is skipped;
an unsupported state change fails without posting a keyboard event. Success means
the native request was accepted; the transition may finish asynchronously.

## Responsibility Boundary

Rust owns workspace input normalization. AppKit preserves the resulting folder,
application and Shortcut names, including non-whitespace Unicode format characters.
Native path expansion, filesystem checks and installed-application lookup remain
in the AppKit adapter.

DesktopActionsMacOS owns the default live macOS executor for DesktopActions actions,
including AppKit, Core Graphics, AppleScript, Shortcuts URL, screen capture, and
WindowManagementMacOS integration paths.

Host apps remain responsible for permission onboarding, user-facing prompts,
shortcut registration, recovery UI, persistence, analytics, telemetry, privacy
disclosures, and deciding which actions are exposed.

## Launching an application

An explicit `.app` path targets the installation at that location. The workspace can
reuse that copy when it is already running, but cannot substitute a running copy at
another location. The adapter does not request a new instance. Name and bundle
identifier launches keep the default workspace substitution policy.

## Permissions

Live execution may require Accessibility, Automation, or Screen Recording depending on the action.
`showWindowOverview` uses the native Mission Control launcher for its primary attempt; its
Control-Up fallback still requires Accessibility. It does not run an AppleScript.
Use `ActionPreflight.permissionHints(for:)` before execution when the host app needs to explain
permission requirements to users.

DesktopActionsMacOS keeps permission UX injectable instead of depending on a specific onboarding
library. Hosts using `SystemPermissionsMacOS` can implement
``ActionExecutorConfiguration/Permissions`` hooks with its status checks, explicit requests and
System Settings navigation. Automation checks must select the target application. Hosts decide
when a prompt is appropriate and handle unknown, unsupported and failed results explicitly;
DesktopActions keeps its permission hints action-specific.

## Shortcuts Catalog

`ShortcutsCatalog` lists system shortcut names with bounded process I/O. It
never executes a shortcut. Hosts choose deadline/output limits, own picker state
and decide whether names may appear in diagnostics. Cancellation throws
`CancellationError`; other failures use `ShortcutsCatalogError` without raw
output. The child process is stopped and reaped before cancellation or failure
returns. The default limit is one MiB and the default timeout is ten seconds.

## Topics

### Execution

- ``ActionExecutor``
- ``ActionExecutor/init(configuration:)``
- ``ActionExecutor/execute(_:beforeStep:)``
- ``ActionExecutorConfiguration``
- ``ActionExecutorConfiguration/init(permissions:log:)``
- ``ActionExecutorConfiguration/Permissions``
- ``ActionExecutorConfiguration/Permissions/init(ensureAccessibility:ensureAutomation:onAutomationDenied:onScreenRecordingRequired:)``
- ``ActionExecutorConfiguration/LogLevel``

### Shortcuts Catalog

- ``ShortcutsCatalog``
- ``ShortcutsCatalog/init(timeout:maximumOutputByteCount:)``
- ``ShortcutsCatalog/shortcutNames()``
- ``ShortcutsCatalogError``
