namespace NaviApps.DesktopActions;

/// <summary>Host-selected behavior after a completed failure or skipped operation.</summary>
public enum ActionSequenceFailureBehavior
{
    /// <summary>Stop after the first completed failure or skipped operation.</summary>
    Stop = 0,
    /// <summary>Continue after completed failures/skips, retaining every result.</summary>
    Continue = 1,
}

/// <summary>Why an ordered request sequence stopped delivering results.</summary>
public enum ActionSequenceStatus
{
    /// <summary>Every request delivered a result, which need not mean effect success.</summary>
    Completed = 1,
    /// <summary>Host policy stopped after a completed failure or skipped operation.</summary>
    Stopped = 2,
    /// <summary>Cancellation stopped further request issuance.</summary>
    Cancelled = 3,
    /// <summary>A worker deadline elapsed; native acknowledgement may still be pending.</summary>
    TimedOut = 4,
    /// <summary>The runner had no free native worker capacity.</summary>
    Busy = 5,
}

/// <summary>Immutable ordered deliveries. Cancellation/timeout does not undo an OS effect.</summary>
public sealed class ActionSequenceReport : IEquatable<ActionSequenceReport>
{
    /// <summary>The Rust-selected terminal sequence status.</summary>
    public ActionSequenceStatus Status { get; }
    /// <summary>Ordered immutable deliveries for requests reached before termination.</summary>
    public IReadOnlyList<ActionRunResult> Results { get; }
    /// <summary>Rust-derived success of all requests, including an empty sequence.</summary>
    public bool AllActionsSucceeded { get; }
    internal ActionSequenceReport(DesktopActionsSequenceSummary summary, IEnumerable<ActionRunResult> results)
    {
        if (!Enum.IsDefined((ActionSequenceStatus)summary.Status))
            throw new InvalidOperationException("Unknown native sequence status.");
        Status = (ActionSequenceStatus)summary.Status;
        Results = Array.AsReadOnly(results.ToArray());
        if (summary.RecordedCount != (nuint)Results.Count)
            throw new InvalidOperationException("Native action sequence and managed projection differ.");
        AllActionsSucceeded = summary.AllActionsSucceeded != 0;
    }

    /// <summary>Compare the terminal status, aggregate success and deliveries in order.</summary>
    public bool Equals(ActionSequenceReport? other) => other is not null && Status == other.Status
        && AllActionsSucceeded == other.AllActionsSucceeded && Results.SequenceEqual(other.Results);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionSequenceReport);
    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Status);
        hash.Add(AllActionsSucceeded);
        foreach (var result in Results) hash.Add(result);
        return hash.ToHashCode();
    }
}
