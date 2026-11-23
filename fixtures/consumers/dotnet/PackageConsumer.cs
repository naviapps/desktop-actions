using NaviApps.DesktopActions;
using NaviApps.WindowManagement;
if (!ActionCatalog.Kinds.Single(k => k.Name == "showWindowOverview").SupportedPlatforms.Contains(ActionPlatform.Windows))
    throw new InvalidOperationException("Packaged platform catalog is unavailable.");
var kind = ActionCatalog.InspectKind("action.window.placement", ActionPlatform.MacOS);
if (!kind.IsExecutable || kind.PermissionHints.Single().Reason != "accessibility-windowing")
    throw new InvalidOperationException("Packaged kind preview failed before placement input.");
var windows = ActionRequest.Create("action.system.lock-screen").Plan(ActionPlatform.Windows);
if (windows.Platform != ActionPlatform.Windows || !windows.IsExecutable ||
    windows.Steps.Single().Instruction is not ActionMethod.LockSession || windows.PrimaryPermissions.Count != 0)
    throw new InvalidOperationException("Packaged Windows planning failed.");
if (!OperatingSystem.IsWindows())
{
    try { _ = WindowsActionExecutor.CaptureForegroundTarget(); throw new InvalidOperationException("The packaged capture API accepted an unsupported OS."); }
    catch (PlatformNotSupportedException) { }
}
var input = new ActionInput.WindowPlacement(new WindowPlacementRequest(WindowPlacement.Fill, DisplayTarget.DisplayIdentifier(ulong.MaxValue)));
var packageInput = ActionInput.FromJson(input.ToJson());
var action = ActionRequest.CreateWithInput("action.window.placement", packageInput);
var restored = ActionRequest.FromUtf8Envelope(System.Text.Encoding.UTF8.GetBytes(action.ToEnvelope()));
if (restored.ToJson() != action.ToJson() || restored.TypedInput?.ToJson() != input.ToJson())
    throw new InvalidOperationException("Packaged shared request codec failed.");
if (new HashSet<ActionRequest> { action, restored }.Count != 1)
    throw new InvalidOperationException("Independently decoded packaged requests must compare by value.");
var plan = action.Plan(ActionPlatform.MacOS);
if (plan.Steps.Single().Instruction is not ActionMethod.WindowPlacement planned ||
    planned.Request.Display.ToJson() != DisplayTarget.DisplayIdentifier(ulong.MaxValue).ToJson())
    throw new InvalidOperationException("Packaged typed planning lost the display identifier.");
var capture = ActionRequest.Create("action.system.capture-screen-full");
var capturePlan = capture.Plan(ActionPlatform.MacOS);
if (new HashSet<ActionPlan> { plan, restored.Plan(ActionPlatform.MacOS), capturePlan, capture.Plan(ActionPlatform.MacOS) }.Count != 2 ||
    new HashSet<ActionMethod> { planned, new ActionMethod.WindowPlacement(input.Request) }.Count != 1)
    throw new InvalidOperationException("Packaged plans and instructions must compare by value.");
var composedPath = ActionRequest.FromUtf8Json("""{"kind":"action.workspace.open-folder","input":"/tmp/caf\u00e9"}"""u8);
var decomposedPath = ActionRequest.FromUtf8Json("""{"kind":"action.workspace.open-folder","input":"/tmp/cafe\u0301"}"""u8);
if (new HashSet<ActionRequest> { composedPath, decomposedPath }.Count != 2 ||
    new HashSet<ActionPlan> { composedPath.Plan(ActionPlatform.MacOS), decomposedPath.Plan(ActionPlatform.MacOS) }.Count != 2)
    throw new InvalidOperationException("Packaged value equality merged different UTF-8 folder paths.");
var frame = Geometry.Frame(WindowPlacement.Fill, new Rect(0, 0, 1200, 800), 4);
if (frame != new Rect(4, 4, 1192, 792)) throw new InvalidOperationException("Packaged dependency runtime failed.");
var report = ActionExecutionReport.FromUtf8Json(
    """{"finalResult":{"status":"success"},"attempts":[{"requiredPermissions":[],"isFallback":false,"result":{"status":"success"}}]}"""u8);
if (!report.Equals(ActionExecutionReport.FromJson(report.ToJson())))
    throw new InvalidOperationException("Packaged execution-report value comparison failed.");
var runner = new ActionRunner(1, TimeSpan.FromSeconds(10));
var result = await runner.RunAsync(action, (_, _) => Task.FromResult(report));
if (result.Status != ActionRunStatus.Completed || result.Report?.FinalResult.Status != ActionResultStatus.Success)
    throw new InvalidOperationException("Packaged native execution pool failed.");
var sequence = await runner.RunSequenceAsync([action], ActionSequenceFailureBehavior.Continue,
    (_, _) => Task.FromResult(ActionExecutionReport.FromJson(report.ToJson())));
var equivalent = await runner.RunSequenceAsync([action], ActionSequenceFailureBehavior.Continue,
    (_, _) => Task.FromResult(report));
if (!sequence.Results.SequenceEqual([result]) || !sequence.Equals(equivalent)
    || sequence.Status != ActionSequenceStatus.Completed || !sequence.AllActionsSucceeded)
    throw new InvalidOperationException("Packaged runner and sequence value comparison failed.");

using var cancellation = new CancellationTokenSource();
cancellation.Cancel();
var visited = false;
IEnumerable<ActionRequest> DeferredRequest()
{
    visited = true;
    yield return action;
}
var cancelled = await runner.RunSequenceAsync(DeferredRequest(), ActionSequenceFailureBehavior.Stop,
    (_, _) => throw new InvalidOperationException("The cancelled package fixture executed an action."),
    cancellationToken: cancellation.Token);
if (cancelled.Status != ActionSequenceStatus.Cancelled || cancelled.Results.Count != 0 || visited)
    throw new InvalidOperationException("The packaged runner enumerated a cancelled input.");

using var duringCapture = new CancellationTokenSource();
IEnumerable<ActionRequest> CooperativeRequests()
{
    yield return action;
    duringCapture.Cancel();
    duringCapture.Token.ThrowIfCancellationRequested();
    yield return action;
}
var captureCancelled = await runner.RunSequenceAsync(CooperativeRequests(), ActionSequenceFailureBehavior.Continue,
    (_, _) => throw new InvalidOperationException("The packaged runner executed a partially captured sequence."),
    cancellationToken: duringCapture.Token);
if (captureCancelled.Status != ActionSequenceStatus.Cancelled || captureCancelled.Results.Count != 0)
    throw new InvalidOperationException("The packaged runner lost the cooperative capture cancellation report.");

using var duringSelection = new CancellationTokenSource();
var calls = 0;
var selectionCancelled = await runner.RunSequenceAsync([action, capture, action], ActionSequenceFailureBehavior.Continue,
    (_, _) =>
    {
        calls++;
        return Task.FromResult(report);
    },
    exemptFromTimeout: request =>
    {
        if (ReferenceEquals(request, capture))
        {
            duringSelection.Cancel();
            duringSelection.Token.ThrowIfCancellationRequested();
        }
        return false;
    },
    cancellationToken: duringSelection.Token);
if (selectionCancelled.Status != ActionSequenceStatus.Cancelled || calls != 1
    || selectionCancelled.Results is not [_, { Status: ActionRunStatus.Cancelled, Report: null }]
    || !selectionCancelled.Results[0].Equals(result))
    throw new InvalidOperationException("The packaged runner did not retain progress through selector cancellation.");
