using System.Text.Json;
using System.Text.Json.Serialization;

namespace NaviApps.DesktopActions;

internal static class ResultJson
{
    internal sealed record ErrorSpec(ActionErrorCode Code, string? DiagnosticMessage, ActionPermission? Permission,
        long? AppleScriptErrorNumber, long? NativeCode);
    internal sealed record SkippedSpec(string Status, ActionSkipReason SkipReason);
    internal sealed record FailureSpec(string Status, JsonElement Error);
    internal sealed record AttemptSpec(ActionPermission[] RequiredPermissions, bool IsFallback, JsonElement Result,
        double? DurationSeconds);

    internal static JsonElement Parse(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes);
        return document.RootElement.Clone();
    }

    internal static JsonElement Decode(ReadOnlySpan<byte> json, uint kind) => Parse(Native.ReadResult(json, kind));
    internal static long? OptionalInt64(JsonElement value, string name) =>
        value.TryGetProperty(name, out var item) ? item.GetInt64() : null;
}

// Nonfinite numbers become strings so Rust rejects them with its usual validation.
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(ResultJson.ErrorSpec))]
[JsonSerializable(typeof(ResultJson.SkippedSpec))]
[JsonSerializable(typeof(ResultJson.FailureSpec))]
[JsonSerializable(typeof(ResultJson.AttemptSpec))]
[JsonSerializable(typeof(ActionErrorCode))]
[JsonSerializable(typeof(ActionPermission))]
[JsonSerializable(typeof(ActionSkipReason))]
[JsonSerializable(typeof(JsonElement[]))]
internal sealed partial class ResultJsonContext : JsonSerializerContext { }
