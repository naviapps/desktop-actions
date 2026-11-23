using System.Text.Json;
using System.Text.Json.Serialization;
namespace NaviApps.DesktopActions;

/// <summary>Adapter targeted by deterministic planning. Planning never executes an instruction.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ActionPlatform>))]
public enum ActionPlatform
{
    /// <summary>AppKit, Accessibility and macOS native effects.</summary>
    [JsonStringEnumMemberName("macos")] MacOS,
    /// <summary>Windows desktop native effects.</summary>
    [JsonStringEnumMemberName("windows")] Windows,
}
/// <summary>macOS privacy requirements. These are not Windows privilege grants.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ActionPermission>))]
[System.Diagnostics.CodeAnalysis.SuppressMessage("Naming", "CA1711:Identifiers should not have incorrect suffix", Justification = "Permission identifies an OS privacy requirement in the public SDK contract, not a code-access security permission.")]
public enum ActionPermission
{
    /// <summary>Input posting and Accessibility window control.</summary>
    [JsonStringEnumMemberName("accessibility")] Accessibility,
    /// <summary>Apple Events automation.</summary>
    [JsonStringEnumMemberName("automation")] Automation,
    /// <summary>Screen content capture.</summary>
    [JsonStringEnumMemberName("screen-recording")] ScreenRecording,
}
/// <summary>One immutable planned instruction, including its fallback role.</summary>
public sealed class ActionPlanStep : IEquatable<ActionPlanStep>
{
    private readonly Lazy<ActionMethod> instruction;
    /// <summary>Canonical instruction name. Native key codes belong to the plan's platform.</summary>
    public string Kind { get; }
    /// <summary>Typed instruction and its owned payload for inspection.</summary>
    [JsonIgnore]
    public ActionMethod Instruction => instruction.Value;
    /// <summary>Owned immutable instruction fields for inspection; not an execution entry point.</summary>
    public JsonElement Method { get; }
    /// <summary>Whether this is a fallback path.</summary>
    public bool IsFallback { get; }
    internal ActionPlanStep(JsonElement step)
    {
        Method = step.GetProperty("method").Clone();
        Kind = Method.GetProperty("kind").GetString()!;
        IsFallback = step.GetProperty("isFallback").GetBoolean();
        instruction = new(() => ActionMethod.FromNative(Method, Kind));
    }

    /// <summary>Compare the instruction and its fallback role.</summary>
    public bool Equals(ActionPlanStep? other) =>
        other is not null && IsFallback == other.IsFallback && Instruction == other.Instruction;
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionPlanStep);
    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Instruction, IsFallback);
}
/// <summary>A permission and the shared reason code a host can localize.</summary>
public sealed class ActionPermissionHint : IEquatable<ActionPermissionHint>
{
    /// <summary>Required privacy permission.</summary>
    public ActionPermission Permission { get; }
    /// <summary>Canonical shared reason code.</summary>
    public string Reason { get; }
    internal ActionPermissionHint(ActionPermission permission, string reason)
    { Permission = permission; Reason = reason; }

    /// <summary>Compare the permission and its canonical reason.</summary>
    public bool Equals(ActionPermissionHint? other) =>
        other is not null && Permission == other.Permission && string.Equals(Reason, other.Reason, StringComparison.Ordinal);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionPermissionHint);
    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Permission, StringComparer.Ordinal.GetHashCode(Reason));
}
/// <summary>Ordered native instructions and permission metadata, all selected by Rust.</summary>
public sealed class ActionPlan : IEquatable<ActionPlan>
{
    /// <summary>Whether Rust has a nonempty valid plan. Does not establish permission, target availability or execution success.</summary>
    public bool IsExecutable { get; }
    /// <summary>Target adapter; codes must not be used by a different platform.</summary>
    public ActionPlatform Platform { get; }
    /// <summary>Ordered instructions. Empty means no plan for this action on the target platform.</summary>
    public IReadOnlyList<ActionPlanStep> Steps { get; }
    /// <summary>Primary-path privacy requirements, in canonical order.</summary>
    public IReadOnlyList<ActionPermission> PrimaryPermissions { get; }
    /// <summary>Fallback-path privacy requirements, in canonical order.</summary>
    public IReadOnlyList<ActionPermission> FallbackPermissions { get; }
    /// <summary>First permission reasons in execution order.</summary>
    public IReadOnlyList<ActionPermissionHint> PermissionHints { get; }
    internal ActionPlan(byte[] bytes, ActionPlatform platform)
    {
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        Platform = root.GetProperty("platform").GetString() switch
        {
            "macos" => ActionPlatform.MacOS,
            "windows" => ActionPlatform.Windows,
            _ => throw new InvalidDataException("Unknown native plan platform."),
        };
        if (Platform != platform) throw new InvalidDataException("Native plan targets another platform.");
        IsExecutable = root.GetProperty("isExecutable").GetBoolean();
        Steps = Array.AsReadOnly(root.GetProperty("steps").EnumerateArray().Select(s => new ActionPlanStep(s)).ToArray());
        var permissions = root.GetProperty("permissions");
        PrimaryPermissions = ReadPermissions(permissions.GetProperty("primary"));
        FallbackPermissions = ReadPermissions(permissions.GetProperty("fallback"));
        PermissionHints = Array.AsReadOnly(root.GetProperty("hints").EnumerateArray().Select(h =>
            new ActionPermissionHint(ReadPermission(h.GetProperty("permission")), h.GetProperty("reason").GetString()!)).ToArray());
    }

    /// <summary>Compare the target, ordered instructions and canonical permission metadata.</summary>
    public bool Equals(ActionPlan? other) =>
        other is not null && Platform == other.Platform && IsExecutable == other.IsExecutable
        && Steps.SequenceEqual(other.Steps) && PrimaryPermissions.SequenceEqual(other.PrimaryPermissions)
        && FallbackPermissions.SequenceEqual(other.FallbackPermissions) && PermissionHints.SequenceEqual(other.PermissionHints);
    /// <inheritdoc />
    public override bool Equals(object? obj) => Equals(obj as ActionPlan);
    /// <inheritdoc />
    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Platform);
        hash.Add(IsExecutable);
        foreach (var step in Steps) hash.Add(step);
        foreach (var permission in PrimaryPermissions) hash.Add(permission);
        foreach (var permission in FallbackPermissions) hash.Add(permission);
        foreach (var hint in PermissionHints) hash.Add(hint);
        return hash.ToHashCode();
    }

    private static System.Collections.ObjectModel.ReadOnlyCollection<ActionPermission> ReadPermissions(JsonElement values) =>
        Array.AsReadOnly(values.EnumerateArray().Select(ReadPermission).ToArray());
    private static ActionPermission ReadPermission(JsonElement value) => value.GetString() switch
    {
        "accessibility" => ActionPermission.Accessibility,
        "automation" => ActionPermission.Automation,
        "screen-recording" => ActionPermission.ScreenRecording,
        _ => throw new InvalidDataException("Unknown native plan permission."),
    };
}
