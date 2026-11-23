using System.Text.Json;
using System.Text.Json.Serialization;

namespace NaviApps.DesktopActions;

/// <summary>Portable failure categories. Native access denial is distinct from macOS privacy consent.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ActionErrorCode>))]
public enum ActionErrorCode
{
    /// <summary>Malformed or unusable operation input.</summary>
    [JsonStringEnumMemberName("invalid-input")] InvalidInput,
    /// <summary>A required macOS privacy permission is unavailable.</summary>
    [JsonStringEnumMemberName("permission-denied")] PermissionDenied,
    /// <summary>The requested resource is absent.</summary>
    [JsonStringEnumMemberName("not-found")] NotFound,
    /// <summary>The OS could not open or launch the requested resource.</summary>
    [JsonStringEnumMemberName("open-failed")] OpenFailed,
    /// <summary>A macOS AppleScript operation failed.</summary>
    [JsonStringEnumMemberName("apple-script-failed")] AppleScriptFailed,
    /// <summary>A screen-capture operation failed.</summary>
    [JsonStringEnumMemberName("screen-capture-failed")] ScreenCaptureFailed,
    /// <summary>An unexpected SDK failure occurred.</summary>
    [JsonStringEnumMemberName("internal-error")] InternalError,
    /// <summary>The operation is not supported by the selected adapter.</summary>
    [JsonStringEnumMemberName("unsupported-action")] UnsupportedAction,
    /// <summary>The OS rejected native operation or target access.</summary>
    [JsonStringEnumMemberName("access-denied")] AccessDenied,
    /// <summary>A native operation failed.</summary>
    [JsonStringEnumMemberName("native-failed")] NativeFailed,
    /// <summary>The deadline elapsed.</summary>
    [JsonStringEnumMemberName("timed-out")] TimedOut,
    /// <summary>All execution capacity is reserved.</summary>
    [JsonStringEnumMemberName("busy")] Busy,
}

/// <summary>An immutable failure created or decoded by Rust, including native diagnostic normalization.</summary>
public sealed class ActionError : IEquatable<ActionError>
{
    private readonly JsonElement value;
    /// <summary>The canonical failure category.</summary>
    public ActionErrorCode Code { get; }
    /// <summary>Developer-facing diagnostics; not localized product copy.</summary>
    public string DiagnosticMessage { get; }
    /// <summary>The associated macOS privacy permission, if any.</summary>
    public ActionPermission? Permission { get; }
    /// <summary>The associated macOS script error number, if any.</summary>
    public long? AppleScriptErrorNumber { get; }
    /// <summary>The OS error number for native access or operation failures, if any.</summary>
    public long? NativeCode { get; }
    internal ActionError(JsonElement value)
    {
        this.value = value.Clone();
        Code = value.GetProperty("code").Deserialize(ResultJsonContext.Default.ActionErrorCode);
        DiagnosticMessage = value.GetProperty("diagnosticMessage").GetString()!;
        Permission = value.TryGetProperty("permission", out var permission)
            ? permission.Deserialize(ResultJsonContext.Default.ActionPermission) : null;
        AppleScriptErrorNumber = ResultJson.OptionalInt64(value, "appleScriptErrorNumber");
        NativeCode = ResultJson.OptionalInt64(value, "nativeCode");
    }
    /// <summary>Decode structured error JSON, rejecting invalid fields and combinations.</summary>
    public static ActionError FromJson(string json) => FromUtf8Json(Native.EncodeUtf8(json));
    /// <summary>Decode original UTF-8 error JSON through Rust's strict codec.</summary>
    public static ActionError FromUtf8Json(ReadOnlySpan<byte> json) => new(ResultJson.Decode(json, 0));
    /// <summary>Create a failure. Rust checks associated fields and supplies blank-message defaults.</summary>
    public static ActionError Create(ActionErrorCode code, string diagnosticMessage = "",
        ActionPermission? permission = null, long? appleScriptErrorNumber = null, long? nativeCode = null) =>
        new(ResultJson.Parse(Native.CreateError(JsonSerializer.SerializeToUtf8Bytes(
            new ResultJson.ErrorSpec(code, Native.ValidateText(diagnosticMessage), permission, appleScriptErrorNumber, nativeCode),
            ResultJsonContext.Default.ErrorSpec))));
    /// <summary>Return canonical error JSON.</summary>
    public string ToJson() => value.GetRawText();
    internal JsonElement Value => value;

    /// <summary>Compare error fields, including the exact diagnostic spelling.</summary>
    public bool Equals(ActionError? other) => other is not null && Code == other.Code
        && string.Equals(DiagnosticMessage, other.DiagnosticMessage, StringComparison.Ordinal)
        && Permission == other.Permission && AppleScriptErrorNumber == other.AppleScriptErrorNumber
        && NativeCode == other.NativeCode;
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionError);
    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Code, DiagnosticMessage, Permission, AppleScriptErrorNumber, NativeCode);
}
