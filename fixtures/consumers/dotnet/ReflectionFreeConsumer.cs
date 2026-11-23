using System.Text.Json;
using NaviApps.DesktopActions;

#if NATIVE_AOT_FIXTURE
if (System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported)
    throw new InvalidOperationException("The fixture requires Native AOT execution.");
#endif

AppContext.SetSwitch("System.Text.Json.JsonSerializer.IsReflectionEnabledByDefault", false);
if (JsonSerializer.IsReflectionEnabledByDefault)
    throw new InvalidOperationException("The fixture requires JSON reflection to be disabled.");

const string folderIdentifier = "action.workspace.open-folder";
const string folder = "/tmp/cafe\u0301";
var raw = ActionRequest.FromUtf8Json("""{"kind":"action.workspace.open-folder","input":"/tmp/cafe\u0301"}"""u8);
if (raw.Plan(ActionPlatform.Windows).Steps.Single().Instruction is not ActionMethod.OpenFolder { Value: folder } ||
    raw.TypedInput is not ActionInput.Text { Value: folder })
    throw new InvalidOperationException("The packaged action lost the exact typed folder path.");
var descriptor = ActionCatalog.Kinds.Single(entry => entry.Identifier == folderIdentifier);
if (descriptor.InputDescriptor.InputShape != ActionInputShape.Text ||
    descriptor.InputDescriptor.Parameter?.TypedExampleInput is not ActionInput.Text)
    throw new InvalidOperationException("The packaged catalog lost the typed example input.");
ActionInputParameter parameter;
using (var example = JsonDocument.Parse("""{"value":" \u200bfolder\u200b ","shape":"string"}"""))
    parameter = new ActionInputParameter(" \u200blabel ", "\u0085Details.\t", example.RootElement);
if (parameter.TypedExampleInput is not ActionInput.Text { Value: "\u200bfolder\u200b" } ||
    parameter.Name != "label" || parameter.Description != "Details.")
    throw new InvalidOperationException("Packaged metadata must own and normalize its input example.");
var equivalent = new ActionInputParameter("label", "Details.", parameter.ExampleInput);
if (new HashSet<ActionInputParameter> { parameter, equivalent }.Count != 1 ||
    new ActionInputDescriptor("string", parameter) != new ActionInputDescriptor("string", equivalent))
    throw new InvalidOperationException("Packaged canonical metadata must compare by value.");
var composedLabel = new ActionInputParameter("caf\u00e9", "caf\u00e9", parameter.ExampleInput);
var differentName = new ActionInputParameter("cafe\u0301", "caf\u00e9", parameter.ExampleInput);
var differentDescription = new ActionInputParameter("caf\u00e9", "cafe\u0301", parameter.ExampleInput);
if (new HashSet<ActionInputParameter> { composedLabel, differentName, differentDescription }.Count != 3)
    throw new InvalidOperationException("Packaged metadata equality merged different UTF-8 labels.");
foreach (Action invalid in new Action[]
{
    () => _ = new ActionInputParameter("\u200b", "Details.", parameter.ExampleInput),
    () => _ = new ActionInputParameter("label", "Details.", default),
    () => _ = new ActionInputDescriptor("none", parameter),
    () => _ = new ActionInputDescriptor("window-placement", parameter),
    () => _ = new ActionInputDescriptor("string", null),
})
{
    try { invalid(); throw new InvalidOperationException("The packaged metadata accepted an invalid parameter or descriptor."); }
    catch (ActionDataException validation) when (validation.Code == ActionDataError.InvalidData) { }
}
var windowDescriptor = ActionCatalog.Kinds.Single(entry => entry.Identifier == "action.window.placement").InputDescriptor;
if (!windowDescriptor.ToString().Contains("window-placement", StringComparison.Ordinal))
    throw new InvalidOperationException("Packaged window metadata must format through its raw example.");
var input = new ActionInput.Text(" " + folder + " ");
var created = ActionRequest.CreateWithInput(folderIdentifier, input);
var restored = ActionRequest.FromEnvelope(created.ToEnvelope());
if (ActionInput.FromJson(input.ToJson()) is not ActionInput.Text { Value: folder } ||
    created.ToJson() != raw.ToJson() || restored.ToJson() != raw.ToJson() ||
    new HashSet<ActionRequest> { raw, created, restored }.Count != 1)
    throw new InvalidOperationException("The packaged action codec lost the normalized text input.");
var zero = ActionRequest.FromUtf8Json("""
    {"kind":"action.window.placement","input":{"placement":{"kind":"fill"},"screen":{"kind":"point","x":0.0,"y":2.0}}}
    """u8);
var negativeZero = ActionRequest.FromUtf8Json("""
    {"kind":"action.window.placement","input":{"placement":{"kind":"fill"},"screen":{"kind":"point","x":-0.0,"y":2.0}}}
    """u8);
if (new HashSet<ActionRequest> { zero, negativeZero }.Count != 1 || zero.ToJson() == negativeZero.ToJson())
    throw new InvalidOperationException("Packaged request equality must compare signed zero without projecting a window type.");
var evaluation = ActionTextInput.Evaluate(folderIdentifier, input.Value, ActionPlatform.Windows, directoryExists: false);
if (evaluation.CanConfirm || evaluation.Issue != "directory-unavailable" || evaluation.NormalizedValue != folder)
    throw new InvalidOperationException("The packaged text evaluator lost its injected observation.");
var shortcut = ActionTextInput.Evaluate("action.workspace.run-shortcut", " morning ", shortcuts: ["Morning"]);
if (!shortcut.CanConfirm || shortcut.ConfirmedValue != "Morning")
    throw new InvalidOperationException("The packaged text evaluator lost the observed Shortcut name.");

var action = ActionRequest.Create("action.editing.copy");
var runner = new ActionRunner(1, TimeSpan.FromSeconds(2));
var thrown = await runner.RunAsync(action, (_, _) => throw new InvalidOperationException("private fixture message"))
    .WaitAsync(TimeSpan.FromSeconds(5));
if (thrown.Status != ActionRunStatus.Completed || thrown.Report?.FinalResult.Error is not { Code: ActionErrorCode.InternalError } error ||
    error.DiagnosticMessage.Contains("private fixture message", StringComparison.Ordinal))
    throw new InvalidOperationException("The runner did not deliver a structured failure.");

var missing = await runner.RunAsync(action, (_, _) => Task.FromResult<ActionExecutionReport>(null!))
    .WaitAsync(TimeSpan.FromSeconds(5));
if (missing.Status != ActionRunStatus.Completed || missing.Report?.FinalResult.Error?.Code != ActionErrorCode.InternalError)
    throw new InvalidOperationException("The runner did not deliver a structured failure for an absent report.");

var skipped = ActionResult.Skipped(ActionSkipReason.NoFocusedWindow);
var denied = ActionError.Create(ActionErrorCode.PermissionDenied, permission: ActionPermission.Automation, appleScriptErrorNumber: -1743);
var failed = ActionResult.Failure(denied);
var attempt = ActionAttempt.Create([ActionPermission.Automation, ActionPermission.Accessibility], false, failed, 0.125);
var fallback = ActionAttempt.Create([], true, skipped);
var report = ActionExecutionReport.Create([attempt, fallback]);
var decoded = ActionExecutionReport.FromUtf8Json(System.Text.Encoding.UTF8.GetBytes(report.ToJson()));
if (!report.Equals(decoded) || !decoded.DidAttemptFallback || decoded.FinalResult.SkipReason != ActionSkipReason.NoFocusedWindow
    || decoded.Attempts[0].Result.Error?.AppleScriptErrorNumber != -1743
    || !decoded.Attempts[0].RequiredPermissions.SequenceEqual([ActionPermission.Accessibility, ActionPermission.Automation]))
    throw new InvalidOperationException("The result codec lost the canonical native fields.");

try
{
    _ = ActionAttempt.Create([], false, ActionResult.Success, double.NaN);
    throw new InvalidOperationException("The result codec accepted an invalid duration.");
}
catch (ActionDataException validation) when (validation.Code == ActionDataError.InvalidData) { }

Console.WriteLine("The packaged text action, catalog and execution results work with JSON reflection disabled.");
