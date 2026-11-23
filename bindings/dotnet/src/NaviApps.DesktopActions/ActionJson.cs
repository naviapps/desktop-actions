using System.Text.Json;
using System.Text.Json.Serialization;

namespace NaviApps.DesktopActions;

internal static class ActionJson
{
    internal sealed record RequestSpec(string? Kind,
        [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] JsonElement? Input = null);
    internal sealed record EnvelopeSpec(int Version, JsonElement Action);
    internal sealed record InputSpec(ActionInputShape Shape, JsonElement Value);
    internal sealed record InputParameterSpec(string? Name, string? Description, JsonElement? ExampleInput);
    internal sealed record InputDescriptorSpec(string? Shape,
        [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] ActionInputParameter? Parameter);
    internal sealed record EvaluationSpec(string? Identifier, string? Value, ActionPlatform Platform,
        IEnumerable<string?>? Shortcuts, bool? DirectoryExists);

    internal static int GetCanonicalValueHashCode(JsonElement? value)
    {
        if (value is not { } element) return 0;
        var hash = new HashCode();
        AddValue(ref hash, element);
        return hash.ToHashCode();
    }

    private static void AddValue(ref HashCode hash, JsonElement value)
    {
        hash.Add(value.ValueKind);
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                // Rust writes the fields of each request variant in canonical order.
                foreach (var property in value.EnumerateObject())
                {
                    hash.Add(property.Name, StringComparer.Ordinal);
                    AddValue(ref hash, property.Value);
                }
                break;
            case JsonValueKind.String:
                hash.Add(value.GetString(), StringComparer.Ordinal);
                break;
            case JsonValueKind.Number:
                // Numeric hashing equates signed zero. Equality checks exact integer values.
                hash.Add(value.GetDouble());
                break;
        }
    }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(ActionDescriptor[]))]
[JsonSerializable(typeof(ActionJson.RequestSpec))]
[JsonSerializable(typeof(ActionJson.EnvelopeSpec))]
[JsonSerializable(typeof(ActionJson.InputSpec))]
[JsonSerializable(typeof(ActionJson.InputParameterSpec))]
[JsonSerializable(typeof(ActionJson.InputDescriptorSpec))]
[JsonSerializable(typeof(ActionJson.EvaluationSpec))]
[JsonSerializable(typeof(JsonElement))]
[JsonSerializable(typeof(string))]
internal sealed partial class ActionJsonContext : JsonSerializerContext { }
