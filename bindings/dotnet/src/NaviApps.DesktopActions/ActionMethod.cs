using System.Collections.ObjectModel;
using System.Text.Json;
using NaviApps.WindowManagement;

namespace NaviApps.DesktopActions;

/// <summary>Shared modifier bits interpreted using the plan's platform.</summary>
[Flags]
public enum ActionModifiers : ushort
{
    /// <summary>No modifiers.</summary>
    None = 0,
    /// <summary>Command on macOS and the Windows key on Windows.</summary>
    Meta = 1 << 0,
    /// <summary>Shift key.</summary>
    Shift = 1 << 1,
    /// <summary>Option on macOS and Alt on Windows.</summary>
    Alt = 1 << 2,
    /// <summary>Control key.</summary>
    Control = 1 << 3,
    /// <summary>Function key where supported.</summary>
    Function = 1 << 4,
}

/// <summary>Typed projection of one Rust-selected native instruction.</summary>
public abstract record ActionMethod
{
    private ActionMethod() { }

    /// <summary>Input failed deterministic validation.</summary>
    /// <param name="Message">The native validation diagnostic.</param>
    public sealed record InvalidInput(string Message) : ActionMethod;

    /// <summary>An adapter-specific native key event.</summary>
    /// <param name="VirtualKeyCode">The virtual key code for the plan's platform.</param>
    /// <param name="Modifiers">The shared modifier bits.</param>
    public sealed record KeyEvent(ushort VirtualKeyCode, ActionModifiers Modifiers) : ActionMethod;

    /// <summary>An adapter-specific media or system control key.</summary>
    /// <param name="Code">The system key code for the plan's platform.</param>
    public sealed record SystemKey(ushort Code) : ActionMethod;

    /// <summary>A shortcut expressed in the shared physical-key syntax.</summary>
    /// <param name="Value">The input shortcut string.</param>
    public sealed record KeyboardShortcut(string Value) : ActionMethod;

    /// <summary>An Apple Events script and its native preparation flags.</summary>
    /// <param name="Source">The script source.</param>
    /// <param name="LaunchesSystemEvents">Whether to prepare System Events.</param>
    /// <param name="UsesAccessibility">Whether the script uses Accessibility.</param>
    public sealed record AppleScript(string Source, bool LaunchesSystemEvents, bool UsesAccessibility) : ActionMethod;

    /// <summary>Open a canonical URL with its system handler.</summary>
    /// <param name="Value">The canonical URL.</param>
    public sealed record OpenUrl(string Value) : ActionMethod;

    /// <summary>Open a folder with the platform file manager.</summary>
    /// <param name="Value">The folder path.</param>
    public sealed record OpenFolder(string Value) : ActionMethod;

    /// <summary>Launch the specified application.</summary>
    /// <param name="Value">The platform-specific name, identifier or path.</param>
    public sealed record LaunchApplication(string Value) : ActionMethod;

    /// <summary>Invoke a named macOS Shortcut.</summary>
    /// <param name="Value">The Shortcut name.</param>
    public sealed record RunShortcut(string Value) : ActionMethod;

    /// <summary>Hide the active application.</summary>
    public sealed record HideFrontmostApplication : ActionMethod;

    /// <summary>Request graceful termination of the active application.</summary>
    public sealed record TerminateFrontmostApplication : ActionMethod;

    /// <summary>Request locking the Windows session.</summary>
    public sealed record LockSession : ActionMethod;

    /// <summary>Ask the Windows shell to toggle the desktop view.</summary>
    public sealed record ToggleDesktop : ActionMethod;

    /// <summary>Request macOS screen capture.</summary>
    /// <param name="Arguments">Adapter-specific command arguments.</param>
    public sealed record ScreenCapture(IReadOnlyList<string> Arguments) : ActionMethod
    {
        private readonly ReadOnlyCollection<string> arguments = CopyArguments(Arguments);

        /// <summary>Owned command arguments in dispatch order.</summary>
        public IReadOnlyList<string> Arguments
        {
            get => arguments;
            init => arguments = CopyArguments(value);
        }

        /// <summary>Compare the ordered argument values.</summary>
        public bool Equals(ScreenCapture? other) =>
            other is not null && Arguments.SequenceEqual(other.Arguments, StringComparer.Ordinal);

        /// <inheritdoc />
        public override int GetHashCode()
        {
            var hash = new HashCode();
            foreach (var argument in Arguments) hash.Add(argument, StringComparer.Ordinal);
            return hash.ToHashCode();
        }

        private static ReadOnlyCollection<string> CopyArguments(IReadOnlyList<string> source)
        {
            ArgumentNullException.ThrowIfNull(source);
            return Array.AsReadOnly(source.ToArray());
        }
    }

    /// <summary>Place the focused window according to the shared geometry request.</summary>
    /// <param name="Request">The normalized placement request.</param>
    public sealed record WindowPlacement(WindowPlacementRequest Request) : ActionMethod
    {
        /// <summary>Compare the normalized request values.</summary>
        public bool Equals(WindowPlacement? other) =>
            other is not null && WindowPlacementValue.Equals(Request, other.Request);

        /// <inheritdoc />
        public override int GetHashCode() => WindowPlacementValue.GetHashCode(Request);
    }

    /// <summary>Move the focused window between displays.</summary>
    /// <param name="Request">The normalized movement request.</param>
    public sealed record WindowMove(WindowMoveRequest Request) : ActionMethod
    {
        /// <summary>Compare the normalized request values.</summary>
        public bool Equals(WindowMove? other) =>
            other is not null && string.Equals(Request?.ToJson(), other.Request?.ToJson(), StringComparison.Ordinal);

        /// <inheritdoc />
        public override int GetHashCode() => Request is null ? 0 : StringComparer.Ordinal.GetHashCode(Request.ToJson());
    }

    /// <summary>Minimize the focused window.</summary>
    public sealed record WindowMinimize : ActionMethod;

    /// <summary>Request closing one foreground window.</summary>
    public sealed record WindowClose : ActionMethod;

    /// <summary>Toggle native full-screen state for the focused window.</summary>
    public sealed record WindowToggleFullScreen : ActionMethod;

    internal static ActionMethod FromNative(JsonElement method, string kind) => kind switch
    {
        "invalid-input" => new InvalidInput(method.GetProperty("message").GetString()!),
        "key-event" => new KeyEvent(method.GetProperty("keyCode").GetUInt16(),
            (ActionModifiers)method.GetProperty("modifiers").GetUInt16()),
        "system-key" => new SystemKey(method.GetProperty("code").GetUInt16()),
        "keyboard-shortcut" => new KeyboardShortcut(method.GetProperty("value").GetString()!),
        "apple-script" => new AppleScript(method.GetProperty("source").GetString()!,
            method.GetProperty("launchesSystemEvents").GetBoolean(), method.GetProperty("usesAccessibility").GetBoolean()),
        "open-url" => new OpenUrl(method.GetProperty("value").GetString()!),
        "open-folder" => new OpenFolder(method.GetProperty("value").GetString()!),
        "launch-application" => new LaunchApplication(method.GetProperty("value").GetString()!),
        "run-shortcut" => new RunShortcut(method.GetProperty("value").GetString()!),
        "hide-frontmost-application" => new HideFrontmostApplication(),
        "terminate-frontmost-application" => new TerminateFrontmostApplication(),
        "lock-session" => new LockSession(),
        "toggle-desktop" => new ToggleDesktop(),
        "screen-capture" => new ScreenCapture(method.GetProperty("arguments").EnumerateArray()
            .Select(argument => argument.GetString()!).ToArray()),
        "window-placement" => new WindowPlacement(WindowPlacementRequest.FromJson(method.GetProperty("request").GetRawText())),
        "window-move" => new WindowMove(WindowMoveRequest.FromJson(method.GetProperty("request").GetRawText())),
        "window-minimize" => new WindowMinimize(),
        "window-close" => new WindowClose(),
        "window-toggle-full-screen" => new WindowToggleFullScreen(),
        _ => throw new InvalidDataException($"Unknown native plan instruction: {kind}."),
    };
}
