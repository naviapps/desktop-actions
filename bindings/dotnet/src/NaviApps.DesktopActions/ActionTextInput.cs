using System.Text.Json;

namespace NaviApps.DesktopActions;

/// <summary>A Rust-evaluated proposal; callers retain their original editable draft.</summary>
public sealed class ActionTextInputEvaluation
{
    /// <summary>Shared Unicode-whitespace normalization, preserving format characters.</summary>
    public string NormalizedValue { get; }
    /// <summary>Canonical Shortcut name when unambiguous, otherwise the normalized input.</summary>
    public string ConfirmedValue { get; }
    /// <summary>Portable Rust issue identifier, or null. Hosts supply localized feedback.</summary>
    public string? Issue { get; }
    /// <summary>Whether the proposal passes supplied observations and the platform plan.</summary>
    public bool CanConfirm { get; }
    internal ActionTextInputEvaluation(JsonElement value)
    {
        NormalizedValue = value.GetProperty("normalizedValue").GetString()!;
        ConfirmedValue = value.GetProperty("confirmedValue").GetString()!;
        Issue = value.GetProperty("issue").GetString();
        CanConfirm = value.GetProperty("canConfirm").GetBoolean();
    }
}

/// <summary>Pure input evaluation with caller-owned catalogs and native observations.</summary>
public static class ActionTextInput
{
    /// <summary>Evaluates without modifying the draft, enumerating targets or executing effects.</summary>
    /// <param name="identifier">Canonical identifier of a string-input action.</param>
    /// <param name="value">Original draft input.</param>
    /// <param name="platform">Target adapter for executable-input validation.</param>
    /// <param name="shortcuts">Optional catalog. Null or empty permits manual entry.</param>
    /// <param name="directoryExists">Optional observation of the normalized folder path.</param>
    /// <returns>A proposed confirmation and portable issue code.</returns>
    public static ActionTextInputEvaluation Evaluate(string identifier, string value,
        ActionPlatform platform = ActionPlatform.MacOS, IReadOnlyList<string>? shortcuts = null,
        bool? directoryExists = null)
    {
        var request = JsonSerializer.SerializeToUtf8Bytes(
            new ActionJson.EvaluationSpec(Native.ValidateText(identifier), Native.ValidateText(value),
                platform, shortcuts?.Select(Native.ValidateText), directoryExists),
            ActionJsonContext.Default.EvaluationSpec);
        using var document = JsonDocument.Parse(Native.EvaluateTextInput(request));
        return new ActionTextInputEvaluation(document.RootElement);
    }
}
