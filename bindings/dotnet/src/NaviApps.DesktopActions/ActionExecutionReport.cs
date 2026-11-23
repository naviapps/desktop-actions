using System.Text.Json;

namespace NaviApps.DesktopActions;

/// <summary>A Rust-validated nonempty execution report with a consistent derived final result.</summary>
public sealed class ActionExecutionReport : IEquatable<ActionExecutionReport>
{
    private readonly JsonElement value;
    /// <summary>Ordered immutable attempt records.</summary>
    public IReadOnlyList<ActionAttempt> Attempts { get; }
    /// <summary>The final operation result, derived by Rust.</summary>
    public ActionResult FinalResult { get; }
    /// <summary>The last successful attempt, if any.</summary>
    public ActionAttempt? SuccessfulAttempt => Attempts.LastOrDefault(a => a.Result.Status == ActionResultStatus.Success);
    /// <summary>Whether any fallback instruction was attempted.</summary>
    public bool DidAttemptFallback => Attempts.Any(a => a.IsFallback);
    internal ActionExecutionReport(JsonElement value)
    {
        this.value = value.Clone();
        Attempts = Array.AsReadOnly(value.GetProperty("attempts").EnumerateArray().Select(a => new ActionAttempt(a)).ToArray());
        FinalResult = new ActionResult(value.GetProperty("finalResult"));
    }
    /// <summary>Decode report JSON, rejecting empty histories and conflicting final results.</summary>
    public static ActionExecutionReport FromJson(string json) => FromUtf8Json(Native.EncodeUtf8(json));
    /// <summary>Decode original UTF-8 report JSON through Rust's strict codec.</summary>
    public static ActionExecutionReport FromUtf8Json(ReadOnlySpan<byte> json) => new(ResultJson.Decode(json, 3));
    /// <summary>Create a report. An empty internal history records an explicit internal failure.</summary>
    public static ActionExecutionReport Create(IEnumerable<ActionAttempt> attempts)
    {
        ArgumentNullException.ThrowIfNull(attempts);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            attempts.Select(a => a.Value).ToArray(), ResultJsonContext.Default.JsonElementArray);
        return new(ResultJson.Parse(Native.CreateExecutionReport(bytes)));
    }
    /// <summary>Record a host result without inventing native permissions or elapsed time.</summary>
    public static ActionExecutionReport FromResult(ActionResult result) => Create([ActionAttempt.Create([], false, result)]);
    /// <summary>Return canonical report JSON.</summary>
    public string ToJson() => value.GetRawText();

    /// <summary>Compare the attempts in their recorded order. Rust derives the final result.</summary>
    public bool Equals(ActionExecutionReport? other) => other is not null && Attempts.SequenceEqual(other.Attempts);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionExecutionReport);
    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var attempt in Attempts) hash.Add(attempt);
        return hash.ToHashCode();
    }
}
