# Windows execution and acceptance

See the [SDK overview](../README.md) for package installation,
[platform boundaries](../README.md#platform-boundaries) for shared semantics, and
[development and validation](../README.md#development-and-validation) for local build and package commands.

## Windows execution

Inspect Windows instructions without live effects using .NET `ActionRequest.Plan(ActionPlatform.Windows)`
or Swift `ActionRequest.plan(for: .windows)`. Both return Rust-selected instructions
and fallback roles, without querying OS state or opening a native worker.

On Windows 11, Show Desktop uses the documented
[`IShellDispatch4::ToggleDesktop`](https://learn.microsoft.com/en-us/windows/win32/shell/ishelldispatch4-toggledesktop)
operation from an owned STA worker. The shell owns hiding and restoring its windows;
the SDK neither synthesizes a desktop shortcut nor maintains a second window list.
An accepted COM request does not itself prove that the shell completed the transition.
Do not use a window's minimized flag as a Shell completion signal, or automatically
retry a toggle whose visible outcome is unknown: another toggle can reverse an
accepted operation. Rapid hide/restore requests with animations enabled have been
observed to leave the window hidden, including in a native SDK-header control.
The isolated Windows acceptance fixture observes three separate hide/restore
cycles at a one-second user interaction cadence, with animation settings unchanged.
That fixture cadence is not an SDK delay, a completion signal or a guarantee for
rapid repeated requests. Native controls with both transient and persistent STA
lifetimes reproduce the rapid-request limitation; changing the COM binding or
adding an animation-setting override is not an established fix.

`showWindowOverview` opens Mission Control on macOS and Task View on Windows.
`switchToNextVirtualDesktop` and `switchToPreviousVirtualDesktop` switch existing
virtual desktops (Spaces on macOS). `missionControlAppExpose` remains a macOS-only
Mission Control operation. On Windows, overview, desktop navigation and Notification
Center use the documented Windows-key shortcuts; Notification Center opens notifications
and the calendar. They run through the same held-key checks and partial-input recovery
as other keyboard actions.
See [Microsoft's keyboard shortcuts](https://support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows).
An accepted input batch does not prove that Windows policy or another application
allowed the shell operation. No virtual desktop is created implicitly.

Full-screen capture sends Win+PrintScreen and lets Windows save the image in its
configured Screenshots known folder. Selection capture opens the system Snipping
Tool picker with Win+Shift+S; the user chooses a mode and completes or cancels it.
The SDK does not change clipboard, capture, notification or save preferences, and
an accepted shortcut does not prove that a file was saved or a selection completed.
See [Microsoft's print-screen guide](https://support.microsoft.com/en-us/windows/keyboard-shortcut-for-print-screen-601210c0-b3a9-7b58-bc40-bae4dcf5f108)
and [Snipping Tool guide](https://support.microsoft.com/en-us/windows/apps/use-snipping-tool-to-capture-screenshots).

Session lock uses the native `LockWorkStation` request without synthetic input,
changing security settings or introducing a keyboard fallback. It requires an
interactive caller; success means the asynchronous request was accepted, rather
than proof that the session locked. Automated fixtures never invoke lock or sleep.
See [Microsoft's session-lock contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-lockworkstation).

The specific interactive window-capture action remains unavailable: opening a
picker in its previous mode or capturing the current window would not guarantee
the requested user-selected window semantics. The packaged-app Snipping Tool
callback protocol requires host app identity and is not an unpackaged SDK effect.

`.NET WindowsActionExecutor.ExecuteAsync` owns a cancellable native run. Rust posts
physical shortcuts with scan codes, uses Windows editing/media virtual keys, opens
URLs/folders, launches explicit absolute `.exe` paths and delegates window control
to WindowManagement. The input-free `action.editing.select-all` and
`action.editing.find-in-app` use Ctrl+A and Ctrl+F through the editing virtual-key
route. The target app decides how it handles Find. An explicit keyboard shortcut
still uses scan codes.
`closeForegroundWindow` requests an ordinary close on the captured
foreground window, rechecking its native handle/process/thread identity before the
request. The application may prompt to save, refuse or close asynchronously; an accepted
request confirms neither closure nor saved data. Closing one window never requests
process termination. `quitFrontmostApplication` requests application-wide graceful
termination on macOS and has no Windows plan. Unsupported operations report
`UnsupportedAction`; no forced-termination fallback is provided.

Input transactions do not release modifiers that were already down. Conflicting
held modifiers and an already-held main key are rejected before insertion. Partial
insertion attempts to release only keys pressed by the accepted prefix; a failed
release is reported explicitly. State/focus checks are best effort and cannot make
input atomic with another application's privilege or foreground changes. Successful
insertion is not a claim that a target application performed the intended command.

Managed hosts can capture the current foreground window before queuing work
and explicitly pass that target into a guarded run:

```csharp
using NaviApps.DesktopActions;

using var target = WindowsActionExecutor.CaptureForegroundTarget();
if (target is not null)
{
    var action = ActionRequest.Create("action.editing.copy");
    var result = await WindowsActionExecutor.ExecuteForTargetAsync(action, target);
}
```

Capture returns null if the foreground observation is missing, incomplete or
changes during lookup. The run copies the snapshot before the worker starts.
The caller disposes the original after creating any runs that need it. The
snapshot contains no portable identity for persistence or IPC. Swift macOS
hosts supply their own authorization check through the executor's `beforeStep`
hook around permission preparation and dispatch.

Rust hosts that capture a target before queuing execution can use
`desktop_actions_windows::execute_for_target(action, cancelled, application, window)`.
The application snapshot must include its nonzero process creation token and executable
identifier, and its PID must match the captured `WindowIdentity`. The executor checks
the exact foreground HWND, PID and thread together with the recorded process creation
and executable identity before native effects, including after its input-lock and shell
worker waits. Window operations use that captured identity. A changed or incomplete
target returns a report with `NativeFailed`. Cancellation remains a cancelled task
in .NET and `None` in Rust. `ExecuteAsync` and `execute` continue selecting the
current foreground window at execution time. Hosts own intentional target transitions between actions,
including those caused by launching an application, opening a URL or minimizing a window.
These checks remain best effort: Windows input insertion cannot be made atomic with
another application's foreground changes, and recovery still releases owned partial
input even if focus has changed.

Shell operations initialize an owned STA thread rather than changing the caller's
COM apartment. Launching an application does not invoke a shell or concatenate
arguments. Native worker acknowledgement may wait for a foreign window or shell
extension. The .NET `ActionRunner` supplies Rust-owned capacity/deadline arbitration,
retaining cancelled or timed-out reservations until the operation actually returns:

```csharp
using NaviApps.DesktopActions;

var action = ActionRequest.Create("action.editing.copy");
var runner = new ActionRunner(maximumConcurrentExecutions: 4, timeout: TimeSpan.FromSeconds(1));
var delivery = await runner.RunAsync(action, WindowsActionExecutor.ExecuteAsync);
```

Hosts retain draft input for editing. Request construction and codecs normalize
text and placement values in Rust. Swift direct enum cases can retain raw text until
a coding or execution boundary; persisted requests use canonical values. Executable
URL validation uses the shared Rust URL parser before either platform performs a workspace effect.
Directly decoded/custom native plans pass through the same executable-value boundary.
The Windows desktop fixture uses owned processes, folder windows and a unique
per-user test URI association; cleanup removes its registration and test resources.
Media-device effects and protected/elevated targets require separate native coverage.

Executable URLs use one canonical representation across platforms; storage retains
the original trimmed input. HTTP URLs require an explicit authority and reject
embedded controls or backslash repair.

## Windows CI and owned acceptance

Public GitHub Actions checks Rust on Windows x64. The maintainer
[distribution workflow](../README.md#distribution-verification) also validates
the C ABI, .NET bindings and installed NuGet consumers against the SDK checkout
and its pinned dependencies. For native desktop effects or x64 emulation
on ARM64, use the local command in an owned desktop.

Run the same acceptance on an owned worker from a clean DesktopActions
checkout. Use a clean SDK Tooling checkout at the revision in
[the SDK Tooling task](../mise.toml) and set `DOTNET_BIN` to the absolute
path of the x64 .NET SDK selected by [`global.json`](../global.json).
The command without `--desktop` runs the C and managed fixtures,
Rust tests and isolated NuGet consumers. Add `--desktop` only when the
desktop belongs to the acceptance fixture. The managed driver exercises the
public SDK against a separate x64 Rust Win32 target with a native edit control.

```powershell
$tooling = 'C:\src\sdk-tooling'
python -I -B (Join-Path $tooling 'ci/run_sdk_tooling.py') python -m distribution.verify_windows --desktop
```

The producer builds the Cargo-locked WindowManagement revision in an exact,
detached checkout and checks that its managed version matches DesktopActions.
Both SDK packages carry only the verified `win-x64` DLL. The managed builds
use an isolated package cache and the WindowManagement NuGet package produced
in the same run. The Windows producer leaves both SDK pins intact.

The accepted package pair, native receipts and coverage record stay below
`VM_RUNNER_ARTIFACTS_DIR/desktop-actions-win-x64` in CI or
`.native-build/desktop-actions-win-x64` locally. The record identifies the
DesktopActions and WindowManagement source revisions, SDK-owned tool
and pinned shared-tool digests, host and execution mode, and retained file digests.

For a separate macOS managed test, use
`make test-dotnet DOTNET_TEST_FLAGS='--package-source /path/to/private-feed'`
with a feed containing the pinned WindowManagement package. Restore uses a fresh cache and does not modify global
NuGet sources.
