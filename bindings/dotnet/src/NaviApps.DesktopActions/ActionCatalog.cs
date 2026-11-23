using System.Text.Json;
using System.Text.Json.Serialization;

namespace NaviApps.DesktopActions;

/// <summary>Input-independent hints for host UI and retry policy; native preflight still applies.</summary>
/// <param name="RequiresFrontmostApplication">Whether the current application or selection is needed.</param>
/// <param name="RequiresFocusedWindow">Whether a focused window is needed.</param>
/// <param name="RequiresInteractiveSelection">Whether native execution asks for interactive selection.</param>
/// <param name="IsDestructive">Whether execution can materially alter user work or system state.</param>
/// <param name="RetryBehavior">Conservative retry behavior: safe, unsafe or context-dependent.</param>
public sealed record ActionCapabilities(bool RequiresFrontmostApplication, bool RequiresFocusedWindow,
    bool RequiresInteractiveSelection, bool IsDestructive, string RetryBehavior);

/// <summary>A host-supplied parameter form described by the shared catalog.</summary>
public sealed record ActionInputParameter
{
    /// <summary>Canonical parameter name.</summary>
    public string Name { get; }
    /// <summary>Explanation for host tooling.</summary>
    public string Description { get; }
    /// <summary>Owned canonical tagged sample input with shape and value.</summary>
    public JsonElement ExampleInput { get; }
    /// <summary>The example projected into its typed input value.</summary>
    [JsonIgnore]
    public ActionInput TypedExampleInput => ActionInput.FromJson(ExampleInput.GetRawText());

    /// <summary>Validate and normalize labels and the tagged example through Rust.</summary>
    /// <exception cref="ActionDataException">A label or example is invalid.</exception>
    [JsonConstructor]
    public ActionInputParameter(string Name, string Description, JsonElement ExampleInput)
    {
        var spec = new ActionJson.InputParameterSpec(Native.ValidateText(Name), Native.ValidateText(Description),
            ExampleInput.ValueKind == JsonValueKind.Undefined ? null : ExampleInput);
        var json = JsonSerializer.SerializeToUtf8Bytes(spec, ActionJsonContext.Default.InputParameterSpec);
        using var canonical = JsonDocument.Parse(Native.NormalizeInputMetadata(json, descriptor: false));
        this.Name = canonical.RootElement.GetProperty("name").GetString()!;
        this.Description = canonical.RootElement.GetProperty("description").GetString()!;
        this.ExampleInput = canonical.RootElement.GetProperty("exampleInput").Clone();
    }

    /// <summary>Extract the normalized metadata.</summary>
    public void Deconstruct(out string Name, out string Description, out JsonElement ExampleInput) =>
        (Name, Description, ExampleInput) = (this.Name, this.Description, this.ExampleInput);

    /// <summary>Compare the canonical labels and tagged example by value.</summary>
    public bool Equals(ActionInputParameter? other) => other is not null &&
        Name == other.Name && Description == other.Description &&
        JsonElement.DeepEquals(ExampleInput, other.ExampleInput);

    /// <inheritdoc />
    public override int GetHashCode() => HashCode.Combine(Name, Description,
        ActionJson.GetCanonicalValueHashCode(ExampleInput));

    /// <summary>Formats the labels and raw example without projecting the typed input.</summary>
    public override string ToString() =>
        $"ActionInputParameter {{ Name = {Name}, Description = {Description}, ExampleInput = {ExampleInput} }}";
}

/// <summary>The shape and optional parameter metadata of a kind's input.</summary>
public sealed record ActionInputDescriptor
{
    /// <summary>The canonical name of the input shape.</summary>
    public string Shape { get; }
    /// <summary>Parameter metadata; absent for input-free actions.</summary>
    public ActionInputParameter? Parameter { get; }
    /// <summary>The typed input shape from the Rust catalog.</summary>
    [JsonIgnore]
    public ActionInputShape InputShape => ActionInput.ReadShape(Shape);

    /// <summary>Validate that the shape and parameter agree through Rust.</summary>
    /// <exception cref="ActionDataException">The shape and parameter do not form valid metadata.</exception>
    [JsonConstructor]
    public ActionInputDescriptor(string Shape, ActionInputParameter? Parameter)
    {
        var spec = new ActionJson.InputDescriptorSpec(Native.ValidateText(Shape), Parameter);
        var json = JsonSerializer.SerializeToUtf8Bytes(spec, ActionJsonContext.Default.InputDescriptorSpec);
        using var canonical = JsonDocument.Parse(Native.NormalizeInputMetadata(json, descriptor: true));
        this.Shape = canonical.RootElement.GetProperty("shape").GetString()!;
        this.Parameter = Parameter;
    }

    /// <summary>Extract the validated shape and parameter.</summary>
    public void Deconstruct(out string Shape, out ActionInputParameter? Parameter) =>
        (Shape, Parameter) = (this.Shape, this.Parameter);
}

/// <summary>One shared action catalog entry. Persistence uses Identifier, not Name.</summary>
/// <param name="Name">Language-facing catalog name.</param>
/// <param name="Identifier">Canonical action identifier.</param>
/// <param name="Category">Catalog grouping.</param>
/// <param name="InputDescriptor">Required input form.</param>
/// <param name="InputForm">Semantic input form from Rust; hosts supply control layout and localized copy.</param>
/// <param name="Capabilities">Conservative policy hints, independent of native availability.</param>
/// <param name="SupportedPlatforms">Adapters with a plan for the input form; actual input, permissions and targets still require preflight.</param>
public sealed record ActionDescriptor(string Name, string Identifier, string Category,
    ActionInputDescriptor InputDescriptor, string InputForm, ActionCapabilities Capabilities,
    IReadOnlyList<ActionPlatform> SupportedPlatforms);

/// <summary>Rust-owned action metadata; there is no managed copy of the action registry.</summary>
public static class ActionCatalog
{
    private static readonly Lazy<IReadOnlyList<ActionDescriptor>> Entries = new(() =>
        Array.AsReadOnly((JsonSerializer.Deserialize(Native.ReadCatalog(), ActionJsonContext.Default.ActionDescriptorArray)
            ?? throw new InvalidOperationException("Native action catalog is unavailable."))
            .Select(entry => entry with { SupportedPlatforms = Array.AsReadOnly(entry.SupportedPlatforms.ToArray()) }).ToArray()));
    /// <summary>All kinds, in catalog order. Presence does not promise native OS support.</summary>
    public static IReadOnlyList<ActionDescriptor> Kinds => Entries.Value;

    /// <summary>Inspect availability and permission hints before collecting input.
    /// Plan an actual request to validate its input and inspect instructions.</summary>
    /// <exception cref="ActionDataException">The identifier or target platform is invalid.</exception>
    public static ActionKindPreflight InspectKind(string identifier, ActionPlatform platform)
    {
        ArgumentNullException.ThrowIfNull(identifier);
        return new(new ActionPlan(Native.ReadKindPlan(Native.EncodeUtf8(identifier), platform), platform));
    }
}

/// <summary>Availability and permission guidance for a kind before its input is known.</summary>
public sealed class ActionKindPreflight
{
    /// <summary>The adapter being inspected.</summary>
    public ActionPlatform Platform { get; }
    /// <summary>Whether the catalog kind is supported by the selected adapter.</summary>
    public bool IsExecutable { get; }
    /// <summary>Privacy requirements on the primary path.</summary>
    public IReadOnlyList<ActionPermission> PrimaryPermissions { get; }
    /// <summary>Privacy requirements on fallback paths.</summary>
    public IReadOnlyList<ActionPermission> FallbackPermissions { get; }
    /// <summary>Permission reasons in execution order.</summary>
    public IReadOnlyList<ActionPermissionHint> PermissionHints { get; }

    internal ActionKindPreflight(ActionPlan plan)
    {
        Platform = plan.Platform;
        IsExecutable = plan.IsExecutable;
        PrimaryPermissions = plan.PrimaryPermissions;
        FallbackPermissions = plan.FallbackPermissions;
        PermissionHints = plan.PermissionHints;
    }
}
