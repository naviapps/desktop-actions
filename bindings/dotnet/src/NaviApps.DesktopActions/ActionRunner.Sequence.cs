namespace NaviApps.DesktopActions;

public sealed partial class ActionRunner
{
    /// <summary>Run a captured request list in order using this runner's capacity and deadlines.
    /// Cancellation, timeout and capacity rejection stop; completed failures/skips follow explicit
    /// host policy. An empty captured list completes without invoking an operation.
    /// Inputs are copied and validated before effects. Cancellation is checked before deferred
    /// enumeration and between iteration steps. A cancellation exception from the supplied token
    /// during capture or timeout selection produces a cancelled report. An empty array completes even if cancelled.</summary>
    public async Task<ActionSequenceReport> RunSequenceAsync(IEnumerable<ActionRequest> actions,
        ActionSequenceFailureBehavior failureBehavior,
        Func<ActionRequest, CancellationToken, Task<ActionExecutionReport>> operation,
        Func<ActionRequest, bool>? exemptFromTimeout = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(actions);
        ArgumentNullException.ThrowIfNull(operation);
        if (!Enum.IsDefined(failureBehavior)) throw new ArgumentOutOfRangeException(nameof(failureBehavior));
        var captured = CaptureRequests(actions, cancellationToken);
        if (captured?.Any(action => action is null) == true) throw new ArgumentException("Sequence contains a null action.", nameof(actions));
        // Give Rust an unissued request when cancellation interrupted capture before the count was known.
        using var sequence = Native.CreateSequence(captured?.Count ?? 1, failureBehavior);
        if (sequence.IsInvalid) throw new InvalidOperationException("Native action sequence is unavailable.");
        if (captured is null)
        {
            Native.CancelSequence(sequence);
            return new(Native.SummarizeSequence(sequence), []);
        }
        var results = new List<ActionRunResult>();
        while (true)
        {
            if (cancellationToken.IsCancellationRequested) Native.CancelSequence(sequence);
            var id = Native.NextSequence(sequence);
            if (id == 0) break;
            var action = captured[checked((int)id - 1)];
            bool exempt;
            try { exempt = exemptFromTimeout?.Invoke(action) ?? false; }
            catch (OperationCanceledException error) when (WasCancelledByCaller(error, cancellationToken))
            {
                // RunAsync observes cancellation before reserving a worker for this issued request.
                exempt = false;
            }
            var result = await RunAsync(action, operation, exempt, cancellationToken).ConfigureAwait(false);
            var code = result.Status switch
            {
                ActionRunStatus.Completed => result.Report!.FinalResult.Status switch
                {
                    ActionResultStatus.Success => 1u,
                    ActionResultStatus.Failure => 2u,
                    ActionResultStatus.Skipped => 3u,
                    _ => throw new InvalidOperationException("Unknown operation result."),
                },
                ActionRunStatus.Cancelled => 4u,
                ActionRunStatus.TimedOut => 5u,
                ActionRunStatus.Busy => 6u,
                _ => throw new InvalidOperationException("Unknown runner result."),
            };
            if (Native.RecordSequence(sequence, id, code) != 0)
                throw new InvalidOperationException("Native sequence rejected a runner delivery.");
            results.Add(result);
        }
        return new(Native.SummarizeSequence(sequence), results);
    }

    private static IReadOnlyList<ActionRequest>? CaptureRequests(
        IEnumerable<ActionRequest> actions, CancellationToken cancellationToken)
    {
        if (actions is ActionRequest[] { Length: 0 } empty) return empty;
        if (cancellationToken.IsCancellationRequested) return null;
        if (!cancellationToken.CanBeCanceled || actions is ActionRequest[]) return actions.ToArray();

        var captured = new List<ActionRequest>();
        try
        {
            using var iterator = actions.GetEnumerator();
            while (!cancellationToken.IsCancellationRequested && iterator.MoveNext())
            {
                if (cancellationToken.IsCancellationRequested) return null;
                captured.Add(iterator.Current);
            }
        }
        catch (OperationCanceledException error) when (WasCancelledByCaller(error, cancellationToken))
        {
            return null;
        }
        return cancellationToken.IsCancellationRequested ? null : captured;
    }

    private static bool WasCancelledByCaller(OperationCanceledException error, CancellationToken token) =>
        token.IsCancellationRequested && error.CancellationToken == token;
}
