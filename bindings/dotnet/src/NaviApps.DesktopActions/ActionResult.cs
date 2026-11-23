using System.Text.Json;
using System.Text.Json.Serialization;

namespace NaviApps.DesktopActions;

/// <summary>Non-error reasons an operation could not run.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ActionSkipReason>))]
public enum ActionSkipReason
{
    /// <summary>No foreground application was available.</summary>
    [JsonStringEnumMemberName("no-frontmost-application")] NoFrontmostApplication,
    /// <summary>No focused window was available.</summary>
    [JsonStringEnumMemberName("no-focused-window")] NoFocusedWindow,
}
/// <summary>The outcome of one operation.</summary>
public enum ActionResultStatus
{
    /// <summary>The operation completed.</summary>
    Success,
    /// <summary>No eligible target was available.</summary>
    Skipped,
    /// <summary>The operation failed.</summary>
    Failure,
}
/// <summary>An immutable Rust-validated operation result.</summary>
public sealed class ActionResult : IEquatable<ActionResult>
{
    private readonly JsonElement value;
    /// <summary>The result category.</summary>
    public ActionResultStatus Status { get; }
    /// <summary>The reason for a skipped result.</summary>
    public ActionSkipReason? SkipReason { get; }
    /// <summary>The structured failure, for a failed result.</summary>
    public ActionError? Error { get; }
    internal ActionResult(JsonElement value)
    {
        this.value = value.Clone();
        Status = value.GetProperty("status").GetString() switch
        {
            "success" => ActionResultStatus.Success,
            "skipped" => ActionResultStatus.Skipped,
            "failure" => ActionResultStatus.Failure,
            _ => throw new InvalidDataException("Unknown native result status."),
        };
        SkipReason = value.TryGetProperty("skipReason", out var reason)
            ? reason.Deserialize(ResultJsonContext.Default.ActionSkipReason) : null;
        Error = value.TryGetProperty("error", out var error) ? new ActionError(error) : null;
    }
    /// <summary>Decode result JSON, rejecting associated fields inconsistent with the status.</summary>
    public static ActionResult FromJson(string json) => FromUtf8Json(Native.EncodeUtf8(json));
    /// <summary>Decode original UTF-8 result JSON through Rust's strict codec.</summary>
    public static ActionResult FromUtf8Json(ReadOnlySpan<byte> json) => new(ResultJson.Decode(json, 1));
    /// <summary>A successful operation.</summary>
    public static ActionResult Success { get; } = FromJson("{\"status\":\"success\"}");
    /// <summary>Create a skipped operation.</summary>
    public static ActionResult Skipped(ActionSkipReason skipReason) => FromUtf8Json(JsonSerializer.SerializeToUtf8Bytes(
        new ResultJson.SkippedSpec("skipped", skipReason), ResultJsonContext.Default.SkippedSpec));
    /// <summary>Create a failed operation.</summary>
    public static ActionResult Failure(ActionError error)
    {
        ArgumentNullException.ThrowIfNull(error);
        return FromUtf8Json(JsonSerializer.SerializeToUtf8Bytes(
            new ResultJson.FailureSpec("failure", error.Value), ResultJsonContext.Default.FailureSpec));
    }
    /// <summary>Return canonical result JSON.</summary>
    public string ToJson() => value.GetRawText();
    internal JsonElement Value => value;

    /// <summary>Compare the result category and its associated data.</summary>
    public bool Equals(ActionResult? other) => other is not null && Status == other.Status
        && SkipReason == other.SkipReason && Equals(Error, other.Error);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionResult);
    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Status, SkipReason, Error);
}
