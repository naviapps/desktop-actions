using System.Text;
using System.Text.Json;
using NaviApps.DesktopActions;
using NaviApps.WindowManagement;

static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
var placementPreview = ActionCatalog.InspectKind("action.window.placement", ActionPlatform.MacOS);
Require(placementPreview is { IsExecutable: true, Platform: ActionPlatform.MacOS }
    && placementPreview.PrimaryPermissions is [ActionPermission.Accessibility]
    && placementPreview.PermissionHints.Single().Reason == "accessibility-windowing",
    "Catalog preview estimates permissions without a placement request");
var windowsPlacementPreview = ActionCatalog.InspectKind("action.window.placement", ActionPlatform.Windows);
Require(windowsPlacementPreview is { IsExecutable: true, Platform: ActionPlatform.Windows }
    && windowsPlacementPreview.PrimaryPermissions.Count == 0,
    "Catalog preview honors the Windows privacy boundary");
var unavailablePreview = ActionCatalog.InspectKind("action.workspace.run-shortcut", ActionPlatform.Windows);
Require(!unavailablePreview.IsExecutable && unavailablePreview.PrimaryPermissions.Count == 0
    && unavailablePreview.FallbackPermissions.Count == 0 && unavailablePreview.PermissionHints.Count == 0,
    "An unsupported kind has no permission requirements");
try
{
    _ = ActionCatalog.InspectKind("action.example.unknown", ActionPlatform.Windows);
    throw new InvalidOperationException("Preview accepted an unknown identifier.");
}
catch (ActionDataException error) when (error.Code == ActionDataError.UnknownAction) { }

var openUrl = ActionCatalog.Kinds.Single(entry => entry.Name == "openURL");
var screenSelection = ActionCatalog.Kinds.Single(entry => entry.Name == "captureScreenSelection");
Require(openUrl is { Category: "workspace", Capabilities.RequiresInteractiveSelection: false }
    && screenSelection is { Category: "system", Capabilities: { RequiresInteractiveSelection: true, RetryBehavior: "unsafe" } },
    "Catalog projects categories and capability fields");
Require(ActionCatalog.Kinds.Single(entry => entry.Name == "showWindowOverview").SupportedPlatforms
    is [ActionPlatform.MacOS, ActionPlatform.Windows]
    && ActionCatalog.Kinds.Single(entry => entry.Name == "sleepSystem").SupportedPlatforms is [ActionPlatform.MacOS],
    "Catalog projects both platform support outcomes");
const string invalidUnicode = "\uD800";
const string folderIdentifier = "action.workspace.open-folder";
foreach (var lossy in new Action[]
{
    () => ActionRequest.FromJson($$"""{"kind":"{{folderIdentifier}}","input":"{{invalidUnicode}}"}"""),
    () => ActionRequest.FromEnvelope($$$"""{"version":1,"action":{"kind":"{{{folderIdentifier}}}","input":"{{{invalidUnicode}}}"}}"""),
    () => ActionRequest.CreateWithInput(folderIdentifier, new ActionInput.Text(invalidUnicode)),
    () => ActionCatalog.InspectKind(invalidUnicode, ActionPlatform.MacOS),
    () => ActionInput.FromJson($$"""{"shape":"string","value":"{{invalidUnicode}}"}"""),
    () => new ActionInput.Text(invalidUnicode).ToJson(),
    () => ActionTextInput.Evaluate(folderIdentifier, invalidUnicode),
    () => ActionTextInput.Evaluate("action.workspace.run-shortcut", "\uFFFD", shortcuts: [invalidUnicode]),
    () => ActionError.FromJson($$"""{"code":"invalid-input","diagnosticMessage":"{{invalidUnicode}}"}"""),
    () => ActionError.Create(ActionErrorCode.InvalidInput, invalidUnicode),
})
{
    try { lossy(); throw new InvalidOperationException("Unrepresentable Unicode was silently replaced."); }
    catch (ActionDataException e) when (e.Code == ActionDataError.InvalidData) { }
}
var sample = openUrl.InputDescriptor.Parameter!.TypedExampleInput;
const string exactUnicode = "日本語🙂\uFFFD";
var unicodeInput = new ActionInput.Text(exactUnicode);
var unicodeAction = ActionRequest.CreateWithInput(folderIdentifier, unicodeInput);
Require(ActionInput.FromUtf8Json(Encoding.UTF8.GetBytes(unicodeInput.ToJson())) == unicodeInput,
    "Original-byte input must preserve the replacement character when intentionally supplied.");
Require(ActionRequest.FromUtf8Json(Encoding.UTF8.GetBytes(unicodeAction.ToJson())).TypedInput == unicodeInput,
    "Original-byte action must preserve its target text.");
Require(ActionRequest.FromUtf8Envelope(Encoding.UTF8.GetBytes(unicodeAction.ToEnvelope())).ToJson() == unicodeAction.ToJson(),
    "Original-byte envelope must preserve the canonical action.");
foreach (var invalid in new Action[]
{
    () => ActionInput.FromUtf8Json(CorruptUnicode(unicodeInput.ToJson())),
    () => ActionRequest.FromUtf8Json(CorruptUnicode(unicodeAction.ToJson())),
    () => ActionRequest.FromUtf8Envelope(CorruptUnicode(unicodeAction.ToEnvelope())),
    () => ActionInput.FromUtf8Json("""{"shape":"string","value":"a","value":"b"}"""u8),
    () => ActionRequest.FromUtf8Json("""{"kind":"action.workspace.open-folder","input":"a","input":"b"}"""u8),
})
{
    try { invalid(); throw new InvalidOperationException("The original-byte actions codec accepted malformed input."); }
    catch (ActionDataException e) when (e.Code == ActionDataError.InvalidData) { }
}
Require(openUrl.InputDescriptor.InputShape == ActionInputShape.Text && sample is ActionInput.Text { Value: "https://example.com" },
    "Catalog example projects through the standalone input codec");
var trimmed = ActionRequest.CreateWithInput(openUrl.Identifier, new ActionInput.Text("  https://example.com  "));
var restored = ActionRequest.FromEnvelope(trimmed.ToEnvelope());
Require(restored.TypedInput == sample && restored.TypedInput?.GetHashCode() == sample.GetHashCode(),
    "Typed envelope projection retains the catalog text value");
Require(new HashSet<ActionRequest> { trimmed, restored, ActionRequest.CreateWithInput(openUrl.Identifier, sample!) }.Count == 1,
    "Canonical request equality must retain the value through independent construction and decoding.");
Require(trimmed.ToJson() == ActionRequest.Create(openUrl.Identifier, JsonSerializer.SerializeToElement("https://example.com")).ToJson(),
    "Typed input retains existing request bytes");
var legacyInput = JsonSerializer.SerializeToElement(restored);
Require(!legacyInput.TryGetProperty("TypedInput", out _) && legacyInput.GetProperty("Input").GetString() == "https://example.com",
    "Existing request serialization retains its raw input");
Require(ActionInput.FromJson(new ActionInput.Text("  https://example.com  ").ToJson()) == sample,
    "Standalone text round-trips as a typed input");
try { _ = ActionInput.FromJson("""{"shape":"string","value":null}"""); throw new InvalidOperationException("Accepted malformed standalone input"); }
catch (ActionDataException e) when (e.Code == ActionDataError.InvalidData) { }
try { _ = ActionRequest.FromEnvelope("""{"version":999}"""); throw new InvalidOperationException("Accepted future envelope"); }
catch (ActionDataException e) when (e.Code == ActionDataError.UnsupportedVersion && e.Version == 999) { }
for (var i = 0; i < 1000; ++i)
    Require(ActionRequest.FromJson(trimmed.ToJson()).Input?.GetString() == "https://example.com", "Native JSON copies own their bytes");

var placement = new WindowPlacementRequest(
    WindowPlacement.Grid(2, 2, 1, 0, 1, 2), DisplayTarget.DisplayIdentifier(ulong.MaxValue), DisplayArea.Full, 8);
var placementInput = new ActionInput.WindowPlacement(placement);
var place = ActionRequest.PlaceWindow(placement);
Require(place.TypedInput == placementInput && ActionInput.FromJson(placementInput.ToJson()) == placementInput,
    "Placement input compares by request value and retains its exact display identifier");
var move = new WindowMoveRequest(DisplayCycleDirection.Previous, false);
foreach (var platform in new[] { ActionPlatform.MacOS, ActionPlatform.Windows })
{
    Require(place.Plan(platform).Steps.Single().Instruction is ActionMethod.WindowPlacement placementStep
        && placementStep.Request.ToJson() == placement.ToJson(), $"Typed placement retains the shared request on {platform}");
    Require(ActionRequest.MoveWindow(move).Plan(platform).Steps.Single().Instruction is ActionMethod.WindowMove moveStep
        && moveStep.Request.ToJson() == move.ToJson(), $"Typed movement retains the shared request on {platform}");
}
Console.WriteLine("DesktopActions managed catalog, codecs, ownership and errors passed.");

var copy = ActionRequest.Create("action.editing.copy");
Require(new HashSet<ActionRequest> { copy, ActionRequest.FromJson(copy.ToJson()), ActionRequest.Create("action.editing.paste") }.Count == 2,
    "Input-free request equality must compare the action kind.");
try { _ = WindowsActionExecutor.ExecuteForTargetAsync(copy, null!); throw new InvalidOperationException("Missing target started a Windows run."); }
catch (ArgumentNullException e) when (e.ParamName == "target") { }
if (!OperatingSystem.IsWindows())
{
    try { _ = WindowsActionExecutor.CaptureForegroundTarget(); throw new InvalidOperationException("Capture unexpectedly ran on this OS."); }
    catch (PlatformNotSupportedException) { }
}
var macPlan = copy.Plan(ActionPlatform.MacOS);
var windowsPlan = copy.Plan(ActionPlatform.Windows);
var legacyStep = JsonSerializer.SerializeToElement(windowsPlan.Steps.Single());
Require(!legacyStep.TryGetProperty("Instruction", out _)
    && legacyStep.GetProperty("Method").GetProperty("keyCode").GetUInt16() == 0x43, "Existing step serialization retains its raw method");
Require(macPlan is { Platform: ActionPlatform.MacOS, IsExecutable: true }
    && macPlan.Steps.Single().Instruction is ActionMethod.KeyEvent { VirtualKeyCode: 8, Modifiers: ActionModifiers.Meta }
    && macPlan.PermissionHints.Single().Reason == "accessibility-key-event", "Typed macOS key and permission hint");
Require(windowsPlan is { Platform: ActionPlatform.Windows, IsExecutable: true, PrimaryPermissions.Count: 0 }
    && windowsPlan.Steps.Single().Instruction is ActionMethod.KeyEvent { VirtualKeyCode: 0x43, Modifiers: ActionModifiers.Control }, "Typed Windows key event");
var unsupported = ActionRequest.Create("action.system.sleep-mac").Plan(ActionPlatform.Windows);
Require(!unsupported.IsExecutable && unsupported.Steps.Count == 0, "Unsupported plan projects an empty step list");
var physicalShortcut = ActionRequest.CreateWithInput("action.keyboard.shortcut", new ActionInput.Text("⌃+Page-Down"));
var physicalWindowsPlan = physicalShortcut.Plan(ActionPlatform.Windows);
Require(physicalWindowsPlan.IsExecutable
    && physicalWindowsPlan.Steps.Single().Instruction is ActionMethod.KeyboardShortcut { Value: "⌃+Page-Down" },
    "A physical shortcut projects a typed step and preserves its exact text");
var malformed = ActionRequest.CreateWithInput("action.keyboard.shortcut", new ActionInput.Text("cmd++c")).Plan(ActionPlatform.Windows);
Require(!malformed.IsExecutable && malformed.Steps.Single().Instruction is ActionMethod.InvalidInput { Message.Length: > 0 },
    "Malformed plan projects a typed validation instruction");
var macShowDesktop = ActionRequest.Create("action.system.show-desktop").Plan(ActionPlatform.MacOS);
Require(macShowDesktop.Steps is [{ IsFallback: false }, { IsFallback: true }]
    && macShowDesktop.Steps[0].Instruction is ActionMethod.AppleScript { Source.Length: > 0, LaunchesSystemEvents: true, UsesAccessibility: true }
    && macShowDesktop.Steps[1].Instruction is ActionMethod.KeyEvent { VirtualKeyCode: 103, Modifiers: ActionModifiers.Function }
    && macShowDesktop.PrimaryPermissions is [ActionPermission.Accessibility, ActionPermission.Automation]
    && macShowDesktop.FallbackPermissions is [ActionPermission.Accessibility], "Typed script and fallback metadata");
Require(ActionRequest.Create("action.system.lock-screen").Plan(ActionPlatform.Windows).Steps.Single().Instruction is ActionMethod.LockSession,
    "Typed Windows session lock");
var capture = ActionRequest.Create("action.system.capture-screen-full");
var capturePlan = capture.Plan(ActionPlatform.MacOS);
Require(capturePlan.Steps.Single().Instruction is ActionMethod.ScreenCapture { Arguments: ["-p", "-x"] }
    && capturePlan.PrimaryPermissions is [ActionPermission.ScreenRecording]
    && capturePlan.FallbackPermissions.Count == 0, "Typed capture parameters and permissions");
var equalCapturePlan = capture.Plan(ActionPlatform.MacOS);
Require(new HashSet<ActionMethod> { capturePlan.Steps.Single().Instruction, equalCapturePlan.Steps.Single().Instruction }.Count == 1,
    "Independently decoded screen capture instructions must compare their arguments by value.");
var mutableArguments = new List<string> { "-p" };
var captureMethod = new ActionMethod.ScreenCapture(mutableArguments);
var captureCopy = captureMethod with { Arguments = mutableArguments };
var captureHash = captureMethod.GetHashCode();
mutableArguments[0] = "changed";
Require(captureMethod.Arguments is ["-p"] && captureCopy == captureMethod && captureHash == captureMethod.GetHashCode(),
    "Screen capture must own the arguments supplied at construction and replacement.");
Require(captureMethod != new ActionMethod.ScreenCapture(["changed"])
    && new ActionMethod.ScreenCapture(["-p", "-i"]) != new ActionMethod.ScreenCapture(["-i", "-p"]),
    "Screen capture comparison must distinguish argument contents and order.");
Require(new HashSet<ActionMethod> { place.Plan(ActionPlatform.Windows).Steps.Single().Instruction, new ActionMethod.WindowPlacement(WindowPlacementRequest.FromJson(placement.ToJson())) }.Count == 1,
    "Placement instructions must compare the normalized shared request by value.");
var zeroTarget = new WindowPlacementRequest(WindowPlacement.Fill, DisplayTarget.Point(0.0, 2.0));
var negativeZeroTarget = new WindowPlacementRequest(WindowPlacement.Fill, DisplayTarget.Point(-0.0, 2.0));
Require(zeroTarget.ToJson() != negativeZeroTarget.ToJson()
    && new HashSet<ActionMethod> { new ActionMethod.WindowPlacement(zeroTarget), new ActionMethod.WindowPlacement(negativeZeroTarget) }.Count == 1
    && new HashSet<ActionInput> { new ActionInput.WindowPlacement(zeroTarget), new ActionInput.WindowPlacement(negativeZeroTarget) }.Count == 1,
    "Signed zero must compare as one window coordinate without changing the request bytes.");
var otherDisplay = new WindowPlacementRequest(
    placement.Placement, DisplayTarget.DisplayIdentifier(ulong.MaxValue - 1), placement.Area, placement.Inset);
Require(new ActionMethod.WindowPlacement(placement) != new ActionMethod.WindowPlacement(otherDisplay),
    "Window placement equality must distinguish adjacent 64-bit display identifiers.");
Require(new HashSet<ActionRequest> { ActionRequest.PlaceWindow(zeroTarget), ActionRequest.PlaceWindow(negativeZeroTarget) }.Count == 1
    && new HashSet<ActionRequest> { place, ActionRequest.FromJson(place.ToJson()), ActionRequest.PlaceWindow(otherDisplay) }.Count == 2,
    "Window action identity must compare signed zero and preserve adjacent display identifiers.");
Require(new HashSet<ActionMethod> { new ActionMethod.WindowMove(move), ActionRequest.MoveWindow(move).Plan(ActionPlatform.MacOS).Steps.Single().Instruction }.Count == 1
    && new ActionMethod.WindowMove(move) != new ActionMethod.WindowMove(new WindowMoveRequest(move.Direction, true)),
    "Movement instructions must compare the normalized direction and position policy.");
Require(new HashSet<ActionPlanStep> { capturePlan.Steps.Single(), equalCapturePlan.Steps.Single() }.Count == 1
    && new HashSet<ActionPlan> { capturePlan, equalCapturePlan }.Count == 1
    && new HashSet<ActionPermissionHint> { capturePlan.PermissionHints.Single(), equalCapturePlan.PermissionHints.Single() }.Count == 1,
    "Independently planned results, steps and permission hints must compare by value.");
Require(new HashSet<ActionPlan> { capturePlan, ActionRequest.Create("action.system.capture-screen-selection").Plan(ActionPlatform.MacOS), capture.Plan(ActionPlatform.Windows) }.Count == 3,
    "Plan comparison must distinguish instructions and target platforms.");
const string composedPath = "/tmp/caf\u00E9", decomposedPath = "/tmp/cafe\u0301";
var firstPath = ActionRequest.CreateWithInput(folderIdentifier, new ActionInput.Text(composedPath)).Plan(ActionPlatform.Windows);
var secondPath = ActionRequest.CreateWithInput(folderIdentifier, new ActionInput.Text(decomposedPath)).Plan(ActionPlatform.Windows);
Require(firstPath.Steps.Single().Instruction is ActionMethod.OpenFolder { Value: composedPath }
    && secondPath.Steps.Single().Instruction is ActionMethod.OpenFolder { Value: decomposedPath }
    && new HashSet<ActionPlan> { firstPath, secondPath }.Count == 2,
    "Distinct UTF-8 folder paths must stay distinct in plans.");
Console.WriteLine("DesktopActions managed plan projections passed.");

var nativeError = ActionError.Create(ActionErrorCode.NativeFailed, "  ", nativeCode: 87);
Require(nativeError.DiagnosticMessage == "Native operation failed" && nativeError.NativeCode == 87, "Rust error defaults and native code");
var automationError = ActionError.Create(ActionErrorCode.PermissionDenied, permission: ActionPermission.Automation, appleScriptErrorNumber: -1743);
Require(automationError.DiagnosticMessage == "Permission denied: automation (AppleScript error number -1743)", "Rust error-number normalization");
var failure = ActionResult.Failure(automationError);
var first = ActionAttempt.Create([ActionPermission.Automation], false, failure, 0.25);
var second = ActionAttempt.Create([ActionPermission.ScreenRecording, ActionPermission.Accessibility], true, ActionResult.Success);
var outcome = ActionExecutionReport.Create([first, second]);
Require(outcome.FinalResult.Status == ActionResultStatus.Success && outcome.DidAttemptFallback && outcome.SuccessfulAttempt?.IsFallback == true, "Outcome projection");
Require(outcome.Attempts[0].DurationSeconds == 0.25 && outcome.Attempts[1].DurationSeconds is null, "Optional elapsed time");
Require(outcome.Attempts[1].RequiredPermissions.SequenceEqual(new[] { ActionPermission.Accessibility, ActionPermission.ScreenRecording }), "Rust canonical permission ordering");
Require(ActionExecutionReport.FromJson(outcome.ToJson()).ToJson() == outcome.ToJson(), "Canonical report roundtrip");
Require(ActionError.FromJson(nativeError.ToJson()).NativeCode == 87, "Native failure roundtrip");
Require(ActionResult.FromJson(failure.ToJson()).Error?.AppleScriptErrorNumber == -1743, "Failure roundtrip");
Require(ActionAttempt.FromJson(first.ToJson()).DurationSeconds == 0.25, "Attempt roundtrip");
Require(new HashSet<ActionError> { nativeError, ActionError.FromJson(nativeError.ToJson()) }.Count == 1,
    "Equivalent decoded errors compare by reference.");
Require(new HashSet<ActionResult> { failure, ActionResult.FromJson(failure.ToJson()) }.Count == 1,
    "Equivalent decoded results compare by reference.");
Require(new HashSet<ActionAttempt> { first, ActionAttempt.FromJson(first.ToJson()) }.Count == 1,
    "Equivalent decoded attempts compare by reference.");
Require(new HashSet<ActionExecutionReport> { outcome, ActionExecutionReport.FromJson(outcome.ToJson()) }.Count == 1,
    "Equivalent decoded execution reports compare by reference.");
var composedDiagnostic = ActionError.Create(ActionErrorCode.InvalidInput, "caf\u00E9");
var decomposedDiagnostic = ActionError.Create(ActionErrorCode.InvalidInput, "cafe\u0301");
Require(!composedDiagnostic.Equals(decomposedDiagnostic), "Distinct diagnostic spellings compared equal.");

var zero = ActionAttempt.FromUtf8Json("""{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"},"durationSeconds":0.0}"""u8);
var negativeZero = ActionAttempt.FromUtf8Json("""{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"},"durationSeconds":-0.0}"""u8);
var subAttosecond = ActionAttempt.Create([], false, ActionResult.Success, 1e-19);
var unmeasured = ActionAttempt.Create([], false, ActionResult.Success);
Require(BitConverter.DoubleToInt64Bits(negativeZero.DurationSeconds!.Value) == long.MinValue,
    "The bit pattern of the reported duration changed.");
Require(new HashSet<ActionAttempt> { zero, negativeZero, subAttosecond, unmeasured }.Count == 3,
    "Duration equality must treat signed zero as equal and distinguish tiny or absent measurements.");
Require(!ActionExecutionReport.Create([first, second, zero]).Equals(ActionExecutionReport.Create([second, first, zero])),
    "Execution report equality ignored attempt order.");
var unicodeError = ActionError.Create(ActionErrorCode.InvalidInput, exactUnicode);
var unicodeFailure = ActionResult.Failure(unicodeError);
var unicodeAttempt = ActionAttempt.Create([], false, unicodeFailure);
var unicodeReport = ActionExecutionReport.Create([unicodeAttempt]);
Require(ActionError.FromUtf8Json(Encoding.UTF8.GetBytes(unicodeError.ToJson())).DiagnosticMessage == exactUnicode,
    "Original-byte error must preserve intentionally supplied Unicode.");
Require(ActionResult.FromUtf8Json(Encoding.UTF8.GetBytes(unicodeFailure.ToJson())).ToJson() == unicodeFailure.ToJson(),
    "Original-byte result must round-trip.");
Require(ActionAttempt.FromUtf8Json(Encoding.UTF8.GetBytes(unicodeAttempt.ToJson())).ToJson() == unicodeAttempt.ToJson(),
    "Original-byte attempt must round-trip.");
Require(ActionExecutionReport.FromUtf8Json(Encoding.UTF8.GetBytes(unicodeReport.ToJson())).ToJson() == unicodeReport.ToJson(),
    "Original-byte report must round-trip.");
Require(ActionExecutionReport.Create([]).FinalResult.Error?.Code == ActionErrorCode.InternalError, "Empty internal history is an explicit failure");
Require(ActionExecutionReport.FromResult(ActionResult.Skipped(ActionSkipReason.NoFocusedWindow)).Attempts[0].RequiredPermissions.Count == 0, "Host result metadata is not invented");
foreach (var invalid in new Action[] {
    () => ActionError.FromUtf8Json(CorruptUnicode(unicodeError.ToJson())),
    () => ActionResult.FromUtf8Json(CorruptUnicode(unicodeFailure.ToJson())),
    () => ActionAttempt.FromUtf8Json(CorruptUnicode(unicodeAttempt.ToJson())),
    () => ActionExecutionReport.FromUtf8Json(CorruptUnicode(unicodeReport.ToJson())),
    () => ActionResult.FromUtf8Json("""{"status":"success","status":"success"}"""u8),
    () => ActionError.Create(ActionErrorCode.PermissionDenied),
    () => ActionError.Create(ActionErrorCode.NotFound, nativeCode: 5),
    () => ActionError.FromJson("{\"code\":\"native-failed\",\"diagnosticMessage\":\"failed\",\"nativeCode\":null}"),
    () => ActionResult.FromJson("{\"status\":\"success\",\"status\":\"success\"}"),
    () => ActionAttempt.Create([ActionPermission.Automation, ActionPermission.Automation], false, ActionResult.Success),
    () => ActionAttempt.Create([], false, ActionResult.Success, -1),
    () => ActionAttempt.Create([], false, ActionResult.Success, double.NaN),
    () => ActionAttempt.Create([], false, ActionResult.Success, double.PositiveInfinity),
    () => ActionAttempt.Create([], false, ActionResult.Success, 9223372036854775808d),
    () => ActionExecutionReport.FromJson("{\"finalResult\":{\"status\":\"success\"},\"attempts\":[]}"),
})
{
    try { invalid(); throw new InvalidOperationException("Accepted invalid execution report"); }
    catch (ActionDataException e) when (e.Code == ActionDataError.InvalidData) { }
}
Console.WriteLine("Shared Rust error/result/attempt/outcome validation and managed projections passed.");

var success = ActionExecutionReport.FromResult(ActionResult.Success);
var bounded = new ActionRunner(1, TimeSpan.FromSeconds(5));
using (var alreadyCancelled = new CancellationTokenSource())
{
    alreadyCancelled.Cancel();
    var invoked = false;
    var result = await bounded.RunAsync(copy, (_, _) => { invoked = true; return Task.FromResult(success); }, cancellationToken: alreadyCancelled.Token);
    Require(result.Status == ActionRunStatus.Cancelled && !invoked, "Early cancellation performed work");
}
using (var cancellation = new CancellationTokenSource())
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var handlerEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var handlerRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var task = bounded.RunAsync(copy, async (_, token) =>
    {
        using var registration = token.UnsafeRegister(_ =>
        {
            handlerEntered.SetResult();
            handlerRelease.Task.GetAwaiter().GetResult();
        }, null);
        started.SetResult();
        await release.Task;
        return success;
    }, cancellationToken: cancellation.Token);
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var signal = Task.Run(cancellation.Cancel);
    try
    {
        await handlerEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await signal.WaitAsync(TimeSpan.FromSeconds(5));
        Require((await task.WaitAsync(TimeSpan.FromSeconds(5))).Status == ActionRunStatus.Cancelled, "Cancellation delivery waited for the worker's handler");
        Require((await bounded.RunAsync(copy, (_, _) => Task.FromResult(success))).Status == ActionRunStatus.Busy, "Cancelled uncooperative worker lost its capacity reservation");
    }
    finally
    {
        handlerRelease.SetResult();
        release.SetResult();
    }
    Require((await AwaitCapacity(bounded, copy, success)).Status == ActionRunStatus.Completed, "Worker acknowledgement did not release capacity");
}
var timed = new ActionRunner(1, TimeSpan.FromMilliseconds(250));
using (var cancellation = new CancellationTokenSource())
{
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var task = timed.RunAsync(copy, async (_, token) =>
    {
        started.SetResult(); await Task.Delay(Timeout.InfiniteTimeSpan, token); return success;
    }, exemptFromTimeout: true, cancellationToken: cancellation.Token);
    await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    await Task.Delay(350);
    Require(!task.IsCompleted, "Interactive exemption acquired an ordinary deadline");
    cancellation.Cancel();
    Require((await task.WaitAsync(TimeSpan.FromSeconds(5))).Status == ActionRunStatus.Cancelled, "Exempt operation cancellation");
}
var exceptionResult = await bounded.RunAsync(copy, (_, _) => Task.FromException<ActionExecutionReport>(new InvalidOperationException("private exception marker")));
Require(exceptionResult.Status == ActionRunStatus.Completed && exceptionResult.Report?.FinalResult.Error?.Code == ActionErrorCode.InternalError && !exceptionResult.Report.ToJson().Contains("private exception marker"), "Executor exception leaked raw diagnostics");
for (var i = 0; i < 16; ++i)
{
    var expired = new ActionRunner(1, TimeSpan.FromTicks(1));
    var invoked = false;
    var delivery = await expired.RunAsync(copy, (_, _) => { invoked = true; return Task.FromResult(success); });
    Require(delivery.Status == ActionRunStatus.TimedOut, "An expired execution reported completion");
    await Task.Delay(1);
    Require(!invoked, "A worker began effects after its deadline");
}
foreach (var configuration in new Action[] { () => _ = new ActionRunner(0, TimeSpan.FromSeconds(1)), () => _ = new ActionRunner(1, TimeSpan.Zero), () => _ = new ActionRunner(1, TimeSpan.MaxValue) })
{
    try { configuration(); throw new InvalidOperationException("Accepted invalid policy"); }
    catch (ArgumentOutOfRangeException) { }
}
for (var i = 0; i < 32; ++i)
{
    var runner = new ActionRunner(1, TimeSpan.FromSeconds(5));
    using var cancellation = new CancellationTokenSource();
    var task = runner.RunAsync(copy, (_, _) => Task.FromResult(success), cancellationToken: cancellation.Token);
    cancellation.Cancel();
    var delivery = await task.WaitAsync(TimeSpan.FromSeconds(5));
    Require(delivery.Status is ActionRunStatus.Completed or ActionRunStatus.Cancelled, "Immediate cancellation/completion race");
}
Console.WriteLine("Managed scheduling with Rust-owned cancellation, deadlines and retained capacity passed.");

var paste = ActionRequest.Create("action.editing.paste");
var sequenceCalls = new List<ActionRequest>();
var sequenceFailure = ActionExecutionReport.FromResult(ActionResult.Failure(ActionError.Create(ActionErrorCode.NotFound)));
var sequenceResult = await bounded.RunSequenceAsync(new[] { copy, paste }, ActionSequenceFailureBehavior.Continue,
    (action, _) => { sequenceCalls.Add(action); return Task.FromResult(sequenceCalls.Count == 1 ? sequenceFailure : success); });
Require(sequenceResult.Status == ActionSequenceStatus.Completed && !sequenceResult.AllActionsSucceeded && sequenceResult.Results.Count == 2, "Sequence lost a completed failure or aggregate status");
Require(sequenceCalls.SequenceEqual(new[] { copy, paste }), "Sequence request ordering");
var equivalentSequence = await bounded.RunSequenceAsync([copy, paste], ActionSequenceFailureBehavior.Continue,
    (action, _) => Task.FromResult(ActionExecutionReport.FromJson(
        (ReferenceEquals(action, copy) ? sequenceFailure : success).ToJson())));
Require(new HashSet<ActionRunResult> { sequenceResult.Results[1], equivalentSequence.Results[1] }.Count == 1,
    "Independently delivered actions with the same report compare by reference.");
Require(new HashSet<ActionSequenceReport> { sequenceResult, equivalentSequence }.Count == 1,
    "Equivalent sequence reports compare by reference.");
var reversedSequence = await bounded.RunSequenceAsync([paste, copy], ActionSequenceFailureBehavior.Continue,
    (action, _) => Task.FromResult(ReferenceEquals(action, copy) ? sequenceFailure : success));
Require(!sequenceResult.Equals(reversedSequence), "Sequence report equality ignored delivery order.");
var completedFailure = await bounded.RunSequenceAsync([copy], ActionSequenceFailureBehavior.Continue,
    (_, _) => Task.FromResult(sequenceFailure));
var stoppedFailure = await bounded.RunSequenceAsync([copy], ActionSequenceFailureBehavior.Stop,
    (_, _) => Task.FromResult(sequenceFailure));
Require(completedFailure.Results.SequenceEqual(stoppedFailure.Results) && !completedFailure.Equals(stoppedFailure),
    "Sequence report equality ignored terminal status.");
sequenceCalls.Clear();
sequenceResult = await bounded.RunSequenceAsync(new[] { copy, paste }, ActionSequenceFailureBehavior.Stop,
    (action, _) => { sequenceCalls.Add(action); return Task.FromResult(sequenceFailure); });
Require(sequenceResult.Status == ActionSequenceStatus.Stopped && sequenceCalls.Count == 1, "Sequence ignored host stop policy");
sequenceResult = await bounded.RunSequenceAsync(Array.Empty<ActionRequest>(), ActionSequenceFailureBehavior.Stop,
    (_, _) => throw new InvalidOperationException("Empty sequence executed work"));
Require(sequenceResult.Status == ActionSequenceStatus.Completed && sequenceResult.AllActionsSucceeded, "Empty sequence contract");
using (var cancelledSequence = new CancellationTokenSource())
{
    cancelledSequence.Cancel();
    sequenceResult = await bounded.RunSequenceAsync(new[] { copy, paste }, ActionSequenceFailureBehavior.Continue,
        (_, _) => throw new InvalidOperationException("Cancelled sequence executed work"), cancellationToken: cancelledSequence.Token);
    Require(sequenceResult.Status == ActionSequenceStatus.Cancelled && sequenceResult.Results.Count == 0, "Cancelled sequence issued work");

    var visited = false;
    IEnumerable<ActionRequest> Requests()
    {
        visited = true;
        yield return copy;
    }
    sequenceResult = await bounded.RunSequenceAsync(Requests(), ActionSequenceFailureBehavior.Continue,
        (_, _) => throw new InvalidOperationException("Cancelled sequence executed work"), cancellationToken: cancelledSequence.Token);
    Require(sequenceResult.Status == ActionSequenceStatus.Cancelled && sequenceResult.Results.Count == 0 && !visited,
        "Pre-cancelled sequence visited a deferred source.");
    sequenceResult = await bounded.RunSequenceAsync(Array.Empty<ActionRequest>(), ActionSequenceFailureBehavior.Stop,
        (_, _) => throw new InvalidOperationException("Empty sequence executed work"), cancellationToken: cancelledSequence.Token);
    Require(sequenceResult.Status == ActionSequenceStatus.Completed && sequenceResult.AllActionsSucceeded,
        "Pre-cancellation changed the outcome for a known-empty array.");
}
using (var cancellation = new CancellationTokenSource())
{
    var disposed = false;
    var visitedAfterCancellation = false;
    var claimed = false;
    IEnumerable<ActionRequest> Requests()
    {
        try
        {
            yield return copy;
            cancellation.Cancel();
            yield return paste;
            visitedAfterCancellation = true;
        }
        finally { disposed = true; }
    }

    sequenceResult = await bounded.RunSequenceAsync(Requests(), ActionSequenceFailureBehavior.Continue,
        (_, _) => throw new InvalidOperationException("Cancelled capture executed work"),
        exemptFromTimeout: _ => { claimed = true; return false; }, cancellationToken: cancellation.Token);
    Require(sequenceResult.Status == ActionSequenceStatus.Cancelled && sequenceResult.Results.Count == 0
        && disposed && !visitedAfterCancellation && !claimed,
        "Cancellation during request capture advanced the iterator or issued incomplete work.");
}
using (var cancellation = new CancellationTokenSource())
{
    var disposed = false;
    IEnumerable<ActionRequest> Requests()
    {
        try
        {
            yield return copy;
            cancellation.Cancel();
            cancellation.Token.ThrowIfCancellationRequested();
            yield return paste;
        }
        finally { disposed = true; }
    }

    var delivery = await bounded.RunSequenceAsync(Requests(), ActionSequenceFailureBehavior.Continue,
        (_, _) => throw new InvalidOperationException("Cooperative capture cancellation executed work"),
        cancellationToken: cancellation.Token);
    Require(delivery.Status == ActionSequenceStatus.Cancelled && !delivery.AllActionsSucceeded
        && delivery.Results.Count == 0 && disposed,
        "Deferred enumeration cancellation did not return a typed stopped report.");
}
using (var cancellation = new CancellationTokenSource())
using (var sourceCancellation = new CancellationTokenSource())
{
    IEnumerable<ActionRequest> Requests()
    {
        yield return copy;
        cancellation.Cancel();
        sourceCancellation.Cancel();
        sourceCancellation.Token.ThrowIfCancellationRequested();
        yield return paste;
    }

    try
    {
        await bounded.RunSequenceAsync(Requests(), ActionSequenceFailureBehavior.Continue,
            (_, _) => throw new InvalidOperationException("Interrupted capture executed work"),
            cancellationToken: cancellation.Token);
        throw new InvalidOperationException("The sequence consumed cancellation from the source's independent token.");
    }
    catch (OperationCanceledException error) when (error.CancellationToken == sourceCancellation.Token) { }
}
using (var cancellation = new CancellationTokenSource())
{
    var runner = new ActionRunner(1, TimeSpan.FromSeconds(5));
    var cut = ActionRequest.Create("action.editing.cut");
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var acknowledged = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var claims = new List<ActionRequest>();
    var calls = new System.Collections.Concurrent.ConcurrentQueue<ActionRequest>();
    var task = runner.RunSequenceAsync([copy, paste, cut], ActionSequenceFailureBehavior.Continue,
        async (action, token) =>
        {
            calls.Enqueue(action);
            if (!ReferenceEquals(action, paste)) return success;
            started.SetResult();
            await release.Task;
            acknowledged.SetResult(token.IsCancellationRequested);
            return sequenceFailure;
        },
        exemptFromTimeout: action =>
        {
            claims.Add(action);
            return true;
        },
        cancellationToken: cancellation.Token);
    try
    {
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();
        var delivery = await task.WaitAsync(TimeSpan.FromSeconds(5));
        Require(delivery.Status == ActionSequenceStatus.Cancelled && !delivery.AllActionsSucceeded
            && delivery.Results is [{ Status: ActionRunStatus.Completed, Report: { } firstDelivered }, { Status: ActionRunStatus.Cancelled, Report: null }]
            && firstDelivered.Equals(success), "Cancelling the second worker lost the first delivery.");
        Require(claims.SequenceEqual([copy, paste]) && calls.SequenceEqual([copy, paste]),
            "The sequence claimed or started the third request after cancellation.");
        var busy = await runner.RunAsync(cut, (_, _) => Task.FromResult(success));
        Require(busy.Status == ActionRunStatus.Busy, "The cancelled second worker released capacity before acknowledging.");
    }
    finally { release.TrySetResult(); }
    Require(await acknowledged.Task.WaitAsync(TimeSpan.FromSeconds(5)), "The second worker did not observe cancellation.");
    Require((await AwaitCapacity(runner, cut, success)).Status == ActionRunStatus.Completed,
        "Acknowledging the cancelled worker failed to restore capacity.");
}
foreach (var throwFromSelector in new[] { false, true })
{
    var runner = new ActionRunner(1, TimeSpan.FromSeconds(5));
    var cut = ActionRequest.Create("action.editing.cut");
    using var cancellation = new CancellationTokenSource();
    var claims = new List<ActionRequest>();
    var calls = new List<ActionRequest>();
    var delivery = await runner.RunSequenceAsync([copy, paste, cut], ActionSequenceFailureBehavior.Continue,
        (action, _) =>
        {
            calls.Add(action);
            return Task.FromResult(success);
        },
        exemptFromTimeout: action =>
        {
            claims.Add(action);
            if (ReferenceEquals(action, paste))
            {
                cancellation.Cancel();
                if (throwFromSelector) cancellation.Token.ThrowIfCancellationRequested();
            }
            return true;
        },
        cancellationToken: cancellation.Token);
    Require(delivery.Status == ActionSequenceStatus.Cancelled && !delivery.AllActionsSucceeded
        && delivery.Results is [{ Status: ActionRunStatus.Completed, Report: { } firstDelivered }, { Status: ActionRunStatus.Cancelled, Report: null }]
        && firstDelivered.Equals(success), "Cancellation in the timeout selector lost the first delivery.");
    Require(claims.SequenceEqual([copy, paste]) && calls.SequenceEqual([copy]),
        "The sequence started a cancelled action or claimed another request.");
    Require((await runner.RunAsync(cut, (_, _) => Task.FromResult(success))).Status == ActionRunStatus.Completed,
        "Pre-dispatch cancellation consumed a worker slot.");
}
using (var cancellation = new CancellationTokenSource())
using (var selectorCancellation = new CancellationTokenSource())
{
    try
    {
        await bounded.RunSequenceAsync([copy], ActionSequenceFailureBehavior.Continue,
            (_, _) => throw new InvalidOperationException("Interrupted selection executed work"),
            exemptFromTimeout: _ =>
            {
                cancellation.Cancel();
                selectorCancellation.Cancel();
                selectorCancellation.Token.ThrowIfCancellationRequested();
                return false;
            },
            cancellationToken: cancellation.Token);
        throw new InvalidOperationException("The sequence consumed cancellation from the selector's independent token.");
    }
    catch (OperationCanceledException error) when (error.CancellationToken == selectorCancellation.Token) { }
}
{
    var runner = new ActionRunner(1, TimeSpan.FromSeconds(1));
    var started = new TaskCompletionSource<ActionRequest>(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var claims = new List<ActionRequest>();
    var task = runner.RunSequenceAsync([copy, paste], ActionSequenceFailureBehavior.Continue,
        async (action, _) =>
        {
            started.TrySetResult(action);
            await release.Task;
            return success;
        },
        exemptFromTimeout: action =>
        {
            // The selector observes a Rust-issued request before worker capacity is checked.
            claims.Add(action);
            return false;
        });
    try
    {
        Require(ReferenceEquals(await started.Task.WaitAsync(TimeSpan.FromSeconds(5)), copy), "Wrong first sequence worker.");
        var delivery = await task.WaitAsync(TimeSpan.FromSeconds(5));
        Require(delivery.Status == ActionSequenceStatus.TimedOut && !delivery.AllActionsSucceeded
            && delivery.Results is [{ Status: ActionRunStatus.TimedOut, Report: null }],
            "The sequence failed to preserve its worker timeout.");
        Require(claims.SequenceEqual([copy]), "The sequence claimed another request after timeout.");
        var busy = await runner.RunAsync(paste, (_, _) => Task.FromResult(success));
        Require(busy.Status == ActionRunStatus.Busy && !busy.Equals(delivery.Results[0]),
            "The timed-out worker released capacity before acknowledging.");
    }
    finally { release.TrySetResult(); }
    Require((await AwaitCapacity(runner, paste, success)).Status == ActionRunStatus.Completed,
        "Acknowledging the timed-out worker failed to restore capacity.");
}
{
    var runner = new ActionRunner(1, TimeSpan.FromTicks(9000));
    var release = new TaskCompletionSource<ActionExecutionReport>(TaskCreationOptions.RunContinuationsAsynchronously);
    var claims = new List<ActionRequest>();
    try
    {
        var task = runner.RunSequenceAsync([copy, paste], ActionSequenceFailureBehavior.Continue,
            (_, _) => release.Task, exemptFromTimeout: action =>
            {
                claims.Add(action);
                return false;
            });
        var delivery = await task.WaitAsync(TimeSpan.FromSeconds(5));
        Require(delivery.Status == ActionSequenceStatus.TimedOut && !delivery.AllActionsSucceeded
            && delivery.Results is [{ Status: ActionRunStatus.TimedOut, Report: null }]
            && claims.SequenceEqual([copy]), "The sub-millisecond deadline did not stop the sequence.");
    }
    finally { release.TrySetResult(success); }
}
Console.WriteLine("Rust-owned ordered sequence policy, cancellation, result retention and aggregate success passed.");

static async Task<ActionRunResult> AwaitCapacity(ActionRunner runner, ActionRequest action, ActionExecutionReport success)
{
    var deadline = System.Diagnostics.Stopwatch.StartNew();
    while (deadline.Elapsed < TimeSpan.FromSeconds(5))
    {
        var result = await runner.RunAsync(action, (_, _) => Task.FromResult(success));
        if (result.Status != ActionRunStatus.Busy) return result;
        await Task.Delay(1);
    }
    throw new TimeoutException("Native worker acknowledgement did not release capacity.");
}

Require(ActionCatalog.Kinds.Single(entry => entry.Identifier == "action.workspace.open-url").InputForm == "url", "Shared semantic input form");
var draftInput = "  \u200BMorning\u200B  ";
var inputEvaluation = ActionTextInput.Evaluate("action.workspace.run-shortcut", draftInput,
    shortcuts: ["Morning", "\u200BMorning\u200B"]);
Require(inputEvaluation.CanConfirm && inputEvaluation.ConfirmedValue == "\u200BMorning\u200B", "Input proposals preserve Unicode names");
Require(ActionTextInput.Evaluate("action.workspace.open-folder", "/fixture", directoryExists: false).Issue == "directory-unavailable", "Explicit native directory observation");
Require(ActionTextInput.Evaluate("action.workspace.run-shortcut", "Morning", ActionPlatform.Windows).Issue == "unsupported-platform", "Unsupported input is not substituted");
Console.WriteLine("Shared input forms, draft evaluation and injected observations passed.");

static byte[] CorruptUnicode(string json)
{
    var bytes = Encoding.UTF8.GetBytes(json);
    var textStart = bytes.AsSpan().IndexOf("日本語🙂\uFFFD"u8);
    Require(textStart >= 0, "The Rust-normalized fixture unexpectedly escaped its Unicode text.");
    bytes[textStart] = 0xff;
    return bytes;
}
