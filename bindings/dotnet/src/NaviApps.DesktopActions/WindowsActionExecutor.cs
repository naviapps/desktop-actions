using System.Text;
using System.Text.Json;
namespace NaviApps.DesktopActions;

/// <summary>An owned, opaque observation of a Windows foreground window and its process.</summary>
public sealed class WindowsActionTarget : IDisposable
{
    internal WindowsTargetHandle Handle { get; }

    internal WindowsActionTarget(WindowsTargetHandle handle) => Handle = handle;

    /// <summary>Release the snapshot. Runs already started retain their own copy.</summary>
    public void Dispose() => Handle.Dispose();
}

/// <summary>Native Windows effects using Rust-selected plans, transaction recovery and result reduction.</summary>
public static class WindowsActionExecutor
{
    /// <summary>Capture the current foreground target without changing focus or requesting an effect.
    /// Returns null if a complete, stable target is unavailable. The caller owns the snapshot.</summary>
    public static WindowsActionTarget? CaptureForegroundTarget()
    {
        RequireWindows();
        var handle = Native.CaptureWindowsTarget();
        if (!handle.IsInvalid) return new WindowsActionTarget(handle);
        handle.Dispose();
        return null;
    }

    /// <summary>Execute on an owned native worker. Cancellation waits for acknowledgement;
    /// it cannot undo an accepted OS effect or interrupt every foreign window/shell extension.
    /// Wrap this method in ActionRunner when the caller needs a bounded deadline and shared capacity.</summary>
    public static Task<ActionExecutionReport> ExecuteAsync(ActionRequest action, CancellationToken cancellationToken = default) =>
        ExecuteCoreAsync(action, null, cancellationToken);

    /// <summary>Run while the captured foreground window and process still match. Rust rechecks
    /// across worker waits and reports NativeFailed after a target change. The run copies the target
    /// before queuing effects. Cancellation follows the same contract as ExecuteAsync.</summary>
    public static Task<ActionExecutionReport> ExecuteForTargetAsync(
        ActionRequest action, WindowsActionTarget target, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(target);
        return ExecuteCoreAsync(action, target, cancellationToken);
    }

    private static async Task<ActionExecutionReport> ExecuteCoreAsync(
        ActionRequest action, WindowsActionTarget? target, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(action);
        RequireWindows();
        cancellationToken.ThrowIfCancellationRequested();
        var actionBytes = Encoding.UTF8.GetBytes(action.ToJson());
        using var run = target is null
            ? Native.CreateWindows(actionBytes)
            : Native.CreateWindowsForTarget(actionBytes, target.Handle);
        if (run.IsInvalid) throw new InvalidDataException("Cannot create a native Windows execution.");
        using var registration = cancellationToken.UnsafeRegister(static state => Native.CancelWindows((WindowsRunHandle)state!), run);
        // Cancellation must not prevent this delegate from starting: it owns the native acknowledgement.
        var bytes = await Task.Run(() => Native.ExecuteWindows(run), CancellationToken.None).ConfigureAwait(false);
        using var document = JsonDocument.Parse(bytes);
        return document.RootElement.GetProperty("status").GetString() switch
        {
            "completed" => new ActionExecutionReport(document.RootElement.GetProperty("outcome")),
            "cancelled" => throw new OperationCanceledException(cancellationToken),
            _ => throw new InvalidDataException("Unknown native execution report."),
        };
    }

    private static void RequireWindows()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows native execution is required.");
    }
}
