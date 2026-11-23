using System.Text.Json;

namespace NaviApps.DesktopActions;

/// <summary>An immutable measured attempt. Rust owns duration limits and canonical permission ordering.</summary>
public sealed class ActionAttempt : IEquatable<ActionAttempt>
{
    private readonly JsonElement value;
    /// <summary>Canonical ordered privacy requirements, empty on Windows.</summary>
    public IReadOnlyList<ActionPermission> RequiredPermissions { get; }
    /// <summary>Whether this attempt used a fallback instruction.</summary>
    public bool IsFallback { get; }
    /// <summary>The operation result.</summary>
    public ActionResult Result { get; }
    /// <summary>Measured seconds, finite and nonnegative when present. No TimeSpan range restriction is added.</summary>
    public double? DurationSeconds { get; }
    internal ActionAttempt(JsonElement value)
    {
        this.value = value.Clone();
        RequiredPermissions = Array.AsReadOnly(value.GetProperty("requiredPermissions").EnumerateArray()
            .Select(p => p.Deserialize(ResultJsonContext.Default.ActionPermission)).ToArray());
        IsFallback = value.GetProperty("isFallback").GetBoolean();
        Result = new ActionResult(value.GetProperty("result"));
        DurationSeconds = value.TryGetProperty("durationSeconds", out var duration) ? duration.GetDouble() : null;
    }
    /// <summary>Decode attempt JSON, rejecting duplicate permissions and invalid durations.</summary>
    public static ActionAttempt FromJson(string json) => FromUtf8Json(Native.EncodeUtf8(json));
    /// <summary>Decode original UTF-8 attempt JSON through Rust's strict codec.</summary>
    public static ActionAttempt FromUtf8Json(ReadOnlySpan<byte> json) => new(ResultJson.Decode(json, 2));
    /// <summary>Create an attempt, with all invariants and canonical ordering checked by Rust.</summary>
    public static ActionAttempt Create(IEnumerable<ActionPermission> requiredPermissions, bool isFallback,
        ActionResult result, double? durationSeconds = null)
    {
        ArgumentNullException.ThrowIfNull(requiredPermissions);
        ArgumentNullException.ThrowIfNull(result);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            new ResultJson.AttemptSpec(requiredPermissions.ToArray(), isFallback, result.Value, durationSeconds),
            ResultJsonContext.Default.AttemptSpec);
        return new(ResultJson.Parse(Native.ReadResult(bytes, 2)));
    }
    /// <summary>Return canonical attempt JSON.</summary>
    public string ToJson() => value.GetRawText();
    internal JsonElement Value => value;

    /// <summary>Compare the result, canonical permissions, fallback flag and numeric duration.</summary>
    public bool Equals(ActionAttempt? other) => other is not null && IsFallback == other.IsFallback
        && DurationSeconds == other.DurationSeconds && Result.Equals(other.Result)
        && RequiredPermissions.SequenceEqual(other.RequiredPermissions);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionAttempt);
    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var permission in RequiredPermissions) hash.Add(permission);
        hash.Add(IsFallback);
        hash.Add(DurationSeconds);
        hash.Add(Result);
        return hash.ToHashCode();
    }
}
