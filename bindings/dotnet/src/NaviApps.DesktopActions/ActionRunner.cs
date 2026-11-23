using System.Diagnostics;
namespace NaviApps.DesktopActions;

/// <summary>The one terminal delivery chosen by Rust for a reserved execution.</summary>
public enum ActionRunStatus
{
    /// <summary>The operation returned before its deadline.</summary>
    Completed,
    /// <summary>Cancellation won terminal delivery.</summary>
    Cancelled,
    /// <summary>The execution deadline elapsed.</summary>
    TimedOut,
    /// <summary>All native worker reservations are occupied.</summary>
    Busy,
}
/// <summary>A terminal runner delivery. A completed delivery carries its executor report.</summary>
public sealed class ActionRunResult : IEquatable<ActionRunResult>
{
    /// <summary>The terminal category.</summary>
    public ActionRunStatus Status { get; }
    /// <summary>The executor's report, present only for completion.</summary>
    public ActionExecutionReport? Report { get; }
    internal ActionRunResult(ActionRunStatus status, ActionExecutionReport? outcome = null) { Status = status; Report = outcome; }

    /// <summary>Compare the terminal status and any completed execution report.</summary>
    public bool Equals(ActionRunResult? other) => other is not null && Status == other.Status && Equals(Report, other.Report);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionRunResult);
    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Status, Report);
}
/// <summary>Schedules managed executors with Rust-owned capacity, deadlines and exactly-once terminal arbitration.</summary>
public sealed partial class ActionRunner
{
    private readonly ExecutionPoolHandle pool;
    private readonly long origin = Stopwatch.GetTimestamp();
    /// <summary>Use explicit host-selected policy. Invalid or unrepresentable policy is rejected, not clamped.</summary>
    public ActionRunner(int maximumConcurrentExecutions, TimeSpan timeout)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumConcurrentExecutions);
        if (timeout.Ticks <= 0 || (ulong)timeout.Ticks > ulong.MaxValue / 100) throw new ArgumentOutOfRangeException(nameof(timeout));
        pool = Native.CreatePool(maximumConcurrentExecutions, (ulong)timeout.Ticks * 100);
        if (pool.IsInvalid) throw new ArgumentException("Invalid native execution policy.");
    }
    /// <summary>Run an executor. Cancelled or timed-out workers retain capacity until they return.
    /// Timeout exemption is explicit host policy. Non-cancellation executor exceptions become a
    /// generic internal failure without exposing exception text. Cancellation callback failures are observed during cleanup.</summary>
    public async Task<ActionRunResult> RunAsync(ActionRequest action,
        Func<ActionRequest, CancellationToken, Task<ActionExecutionReport>> operation,
        bool exemptFromTimeout = false, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(action); ArgumentNullException.ThrowIfNull(operation);
        if (cancellationToken.IsCancellationRequested) return new(ActionRunStatus.Cancelled);
        var id = Native.Reserve(pool, Now(), exemptFromTimeout ? 1u : 0u);
        if (id == 0) return new(ActionRunStatus.Busy);
        var state = new Run(this, id);
        try
        {
            using var registration = cancellationToken.UnsafeRegister(static value => ((Run)value!).Cancel(), state);
            var worker = Task.Run(() => state.Work(action, operation), CancellationToken.None);
            var timer = state.Timer();
            _ = state.Cleanup(worker, timer);
            return await state.Completion.Task.ConfigureAwait(false);
        }
        finally
        {
            // Cleanup also waits for registration disposal, preventing cancellation/disposal races.
            state.CallerDetached.SetResult();
        }
    }
    private ulong Now()
    {
        var scaled = (UInt128)(ulong)(Stopwatch.GetTimestamp() - origin) * 1_000_000_000 / (ulong)Stopwatch.Frequency;
        return scaled > ulong.MaxValue ? ulong.MaxValue : (ulong)scaled;
    }
    [System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1001:Types that own disposable fields should be disposable", Justification = "Cleanup disposes both sources only after worker, timer, cancellation callbacks and caller detachment complete.")]
    private sealed class Run(ActionRunner owner, ulong id)
    {
        internal readonly TaskCompletionSource<ActionRunResult> Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource CallerDetached = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly CancellationTokenSource workerStop = new(), timerStop = new();
        private Task cancellationCallbacks = Task.CompletedTask;
        internal void Cancel() => Deliver(Native.Cancel(owner.pool, id, owner.Now()));
        private void Deliver(uint terminal, ActionExecutionReport? outcome = null)
        {
            if (terminal == 0) return;
            var result = terminal switch
            {
                1 => new ActionRunResult(ActionRunStatus.Completed, outcome ?? throw new InvalidOperationException("Missing executor report.")),
                2 => new ActionRunResult(ActionRunStatus.Cancelled),
                3 => new ActionRunResult(ActionRunStatus.TimedOut),
                _ => throw new InvalidOperationException("Unknown native terminal code."),
            };
            if (terminal is 2 or 3) cancellationCallbacks = workerStop.CancelAsync();
            Completion.SetResult(result);
            timerStop.Cancel();
        }
        internal async Task Work(ActionRequest action, Func<ActionRequest, CancellationToken, Task<ActionExecutionReport>> operation)
        {
            ActionExecutionReport? result = null;
            try
            {
                // A queued worker can start after its deadline while the managed timer is delayed.
                Deliver(Native.Timeout(owner.pool, id, owner.Now()));
                if (Native.Active(owner.pool, id) == 0) return;
                result = await operation(action, workerStop.Token).ConfigureAwait(false)
                    ?? ActionExecutionReport.FromResult(ActionResult.Failure(ActionError.Create(ActionErrorCode.InternalError, "Executor returned no report")));
            }
            catch (OperationCanceledException) { Cancel(); }
            catch (Exception)
            {
                result = ActionExecutionReport.FromResult(ActionResult.Failure(ActionError.Create(ActionErrorCode.InternalError, "Executor failed")));
            }
            finally { Deliver(Native.Finish(owner.pool, id, owner.Now()), result); }
        }
        internal async Task Timer()
        {
            var deadline = Native.Deadline(owner.pool, id);
            if (deadline == 0) return;
            try
            {
                while (Native.Active(owner.pool, id) != 0)
                {
                    var now = owner.Now();
                    if (now >= deadline) { Deliver(Native.Timeout(owner.pool, id, now)); return; }
                    // Task.Delay uses whole milliseconds. Round the wait up and leave exact deadlines to Rust.
                    var remainingNanoseconds = deadline - now;
                    var milliseconds = Math.Min(1 + (remainingNanoseconds - 1) / 1_000_000,
                        (ulong)TimeSpan.TicksPerDay / TimeSpan.TicksPerMillisecond);
                    await Task.Delay((int)milliseconds, timerStop.Token).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) { }
        }
        internal async Task Cleanup(Task worker, Task timer)
        {
            await Task.WhenAll(worker, timer).ConfigureAwait(false);
            await CallerDetached.Task.ConfigureAwait(false);
            try { await cancellationCallbacks.ConfigureAwait(false); } catch (Exception) { }
            workerStop.Dispose(); timerStop.Dispose();
        }
    }
}
