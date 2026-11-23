using System.Text.Json;
using NaviApps.WindowManagement;

namespace NaviApps.DesktopActions;

// The pinned WindowManagement projection exposes a canonical request but uses reference equality.
internal static class WindowPlacementValue
{
    internal static bool Equals(WindowPlacementRequest? left, WindowPlacementRequest? right)
    {
        if (ReferenceEquals(left, right)) return true;
        if (left is null || right is null) return false;
        using var first = JsonDocument.Parse(left.ToJson());
        using var second = JsonDocument.Parse(right.ToJson());
        return JsonElement.DeepEquals(first.RootElement, second.RootElement);
    }

    internal static int GetHashCode(WindowPlacementRequest? request)
    {
        if (request is null) return 0;
        using var document = JsonDocument.Parse(request.ToJson());
        return ActionJson.GetCanonicalValueHashCode(document.RootElement);
    }
}
