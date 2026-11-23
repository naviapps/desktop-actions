using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using NaviApps.WindowManagement;

namespace NaviApps.DesktopActions;

/// <summary>An immutable request validated and normalized by the shared Rust codec.</summary>
public sealed class ActionRequest : IEquatable<ActionRequest>
{
    private readonly string json;
    private readonly Lazy<ActionInput>? typedInput;
    /// <summary>The canonical action identifier.</summary>
    public string Identifier { get; }
    /// <summary>Owned input data; null for input-free actions.</summary>
    public JsonElement? Input { get; }
    /// <summary>The normalized typed input. Input-free actions return null.</summary>
    [JsonIgnore]
    public ActionInput? TypedInput => typedInput?.Value;
    private ActionRequest(JsonElement canonical)
    {
        json = canonical.GetRawText();
        Identifier = canonical.GetProperty("kind").GetString()!;
        Input = canonical.TryGetProperty("input", out var input) ? input.Clone() : null;
        if (Input is { } value)
        {
            typedInput = new(() => ActionInput.FromValue(
                ActionCatalog.Kinds.First(entry => entry.Identifier == Identifier).InputDescriptor.InputShape, value));
        }
    }
    /// <summary>Parse bare action JSON, rejecting unknown fields and identifiers.</summary>
    public static ActionRequest FromJson(string json) => FromUtf8Json(Native.EncodeUtf8(json));
    /// <summary>Parse original UTF-8 action JSON with Rust's strict codec.</summary>
    public static ActionRequest FromUtf8Json(ReadOnlySpan<byte> json)
    {
        using var canonical = JsonDocument.Parse(Native.Canonical(json, false));
        return new(canonical.RootElement);
    }

    /// <summary>Parse a versioned JSON envelope. Unsupported versions remain distinguishable.</summary>
    public static ActionRequest FromEnvelope(string json) => FromUtf8Envelope(Native.EncodeUtf8(json));
    /// <summary>Parse an original UTF-8 envelope, preserving Rust's version and field checks.</summary>
    public static ActionRequest FromUtf8Envelope(ReadOnlySpan<byte> json)
    {
        using var canonical = JsonDocument.Parse(Native.Canonical(json, true));
        return new(canonical.RootElement.GetProperty("action"));
    }
    /// <summary>Create an input-free action. Kinds that require input fail in Rust.</summary>
    public static ActionRequest Create(string identifier) => FromUtf8Json(
        JsonSerializer.SerializeToUtf8Bytes(
            new ActionJson.RequestSpec(Native.ValidateText(identifier)), ActionJsonContext.Default.RequestSpec));
    /// <summary>Create an action with untagged input data; the kind determines its required shape.</summary>
    public static ActionRequest Create(string identifier, JsonElement input) =>
        FromUtf8Json(JsonSerializer.SerializeToUtf8Bytes(
            new ActionJson.RequestSpec(Native.ValidateText(identifier), input), ActionJsonContext.Default.RequestSpec));
    /// <summary>Create an action from typed input. Rust verifies the kind and normalizes the input.</summary>
    public static ActionRequest CreateWithInput(string identifier, ActionInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        return Create(identifier, input.ToValue());
    }
    /// <summary>Create a focused-window placement action using the shared window SDK's request type.</summary>
    public static ActionRequest PlaceWindow(WindowPlacementRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return CreateWithInput("action.window.placement", new ActionInput.WindowPlacement(request));
    }
    /// <summary>Create a focused-window movement action using the shared window SDK's request type.</summary>
    public static ActionRequest MoveWindow(WindowMoveRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return CreateWithInput("action.window.move", new ActionInput.WindowMove(request));
    }
    /// <summary>Compare the canonical action identifier and validated input.</summary>
    public bool Equals(ActionRequest? other) =>
        other is not null && string.Equals(Identifier, other.Identifier, StringComparison.Ordinal) &&
        (Input is { } input
            ? other.Input is { } otherInput && JsonElement.DeepEquals(input, otherInput)
            : other.Input is null);
    /// <inheritdoc/>
    public override bool Equals(object? obj) => obj is ActionRequest other && Equals(other);
    /// <inheritdoc/>
    public override int GetHashCode() => HashCode.Combine(
        StringComparer.Ordinal.GetHashCode(Identifier), ActionJson.GetCanonicalValueHashCode(Input));
    /// <summary>Return canonical bare action JSON.</summary>
    public string ToJson() => json;
    /// <summary>Inspect the Rust-selected instructions and privacy hints without executing them.</summary>
    public ActionPlan Plan(ActionPlatform platform) => new(Native.ReadPlan(Native.EncodeUtf8(json), platform), platform);
    /// <summary>Return a version 1 envelope suitable for persistence or IPC.</summary>
    public string ToEnvelope()
    {
        // Encoding uses the same validation path as decoding; no managed action semantics are duplicated.
        using var document = JsonDocument.Parse(json);
        var envelope = JsonSerializer.SerializeToUtf8Bytes(
            new ActionJson.EnvelopeSpec(1, document.RootElement), ActionJsonContext.Default.EnvelopeSpec);
        return Encoding.UTF8.GetString(Native.Canonical(envelope, true));
    }
}
