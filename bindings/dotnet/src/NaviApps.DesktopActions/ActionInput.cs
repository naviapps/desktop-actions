using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NaviApps.WindowManagement;

namespace NaviApps.DesktopActions;

/// <summary>The structural shape required by a catalog action.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ActionInputShape>))]
public enum ActionInputShape
{
    /// <summary>The action has no input value.</summary>
    [JsonStringEnumMemberName("none")] None,
    /// <summary>The action accepts kind-specific text.</summary>
    [JsonStringEnumMemberName("string")] Text,
    /// <summary>The action accepts a shared window placement request.</summary>
    [JsonStringEnumMemberName("window-placement")] WindowPlacement,
    /// <summary>The action accepts a shared window movement request.</summary>
    [JsonStringEnumMemberName("window-move")] WindowMove,
}

/// <summary>Host-supplied text, window placement or window movement input.</summary>
public abstract record ActionInput
{
    /// <summary>The structural shape of this input.</summary>
    public ActionInputShape Shape { get; }

    private ActionInput(ActionInputShape shape) => Shape = shape;

    /// <summary>Kind-specific text. Rust normalizes the value when encoding or creating a request.</summary>
    /// <param name="Value">The host's input string.</param>
    public sealed record Text(string Value) : ActionInput(ActionInputShape.Text);

    /// <summary>Input for placing a focused window.</summary>
    /// <param name="Request">The shared placement request.</param>
    public sealed record WindowPlacement(WindowPlacementRequest Request) : ActionInput(ActionInputShape.WindowPlacement)
    {
        /// <summary>Compares the normalized request values.</summary>
        public bool Equals(WindowPlacement? other) =>
            other is not null && WindowPlacementValue.Equals(Request, other.Request);

        /// <summary>Hashes the normalized request value.</summary>
        public override int GetHashCode() => WindowPlacementValue.GetHashCode(Request);
    }

    /// <summary>Input for moving a focused window to another display.</summary>
    /// <param name="Request">The shared movement request.</param>
    public sealed record WindowMove(WindowMoveRequest Request) : ActionInput(ActionInputShape.WindowMove)
    {
        /// <summary>Compares the normalized request values.</summary>
        public bool Equals(WindowMove? other) =>
            other is not null && string.Equals(Request.ToJson(), other.Request.ToJson(), StringComparison.Ordinal);

        /// <summary>Hashes the normalized request value.</summary>
        public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Request.ToJson());
    }

    /// <summary>Parse standalone tagged input with the shared Rust codec.</summary>
    public static ActionInput FromJson(string json) => FromUtf8Json(Native.EncodeUtf8(json));

    /// <summary>Parse original UTF-8 tagged input using Rust's strict codec.</summary>
    public static ActionInput FromUtf8Json(ReadOnlySpan<byte> json)
    {
        using var canonical = JsonDocument.Parse(Native.NormalizeInput(json));
        var root = canonical.RootElement;
        return FromValue(ReadShape(root.GetProperty("shape").GetString()), root.GetProperty("value"));
    }

    /// <summary>Encode canonical tagged input through the shared Rust codec.</summary>
    public string ToJson()
    {
        var tagged = JsonSerializer.SerializeToUtf8Bytes(
            new ActionJson.InputSpec(Shape, ToValue()), ActionJsonContext.Default.InputSpec);
        return Encoding.UTF8.GetString(Native.NormalizeInput(tagged));
    }

    internal JsonElement ToValue() => this switch
    {
        Text text => JsonSerializer.SerializeToElement(Native.ValidateText(text.Value), ActionJsonContext.Default.String),
        WindowPlacement placement => JsonSerializer.Deserialize(placement.Request.ToJson(), ActionJsonContext.Default.JsonElement),
        WindowMove move => JsonSerializer.Deserialize(move.Request.ToJson(), ActionJsonContext.Default.JsonElement),
        _ => throw new InvalidDataException("Unknown action input type."),
    };

    internal static ActionInput FromValue(ActionInputShape shape, JsonElement value) => shape switch
    {
        ActionInputShape.Text => new Text(value.GetString()!),
        ActionInputShape.WindowPlacement => new WindowPlacement(WindowPlacementRequest.FromJson(value.GetRawText())),
        ActionInputShape.WindowMove => new WindowMove(WindowMoveRequest.FromJson(value.GetRawText())),
        _ => throw new InvalidDataException("Unknown action input shape."),
    };

    internal static ActionInputShape ReadShape(string? shape) => shape switch
    {
        "none" => ActionInputShape.None,
        "string" => ActionInputShape.Text,
        "window-placement" => ActionInputShape.WindowPlacement,
        "window-move" => ActionInputShape.WindowMove,
        _ => throw new InvalidDataException($"Unknown action input shape: {shape}."),
    };
}
