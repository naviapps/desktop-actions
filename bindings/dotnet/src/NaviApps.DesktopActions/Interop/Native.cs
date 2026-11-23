using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]

namespace NaviApps.DesktopActions;

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct DesktopActionsJsonView
{
    internal uint Code, HasVersion;
    internal long Version;
    internal byte* Data;
    internal nuint Length;
}

internal static unsafe partial class Native
{
    private const string Library = "desktop_actions_ffi";
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    internal static byte[] EncodeUtf8(string json)
    {
        try { return StrictUtf8.GetBytes(json); }
        catch (EncoderFallbackException) { throw InvalidUnicode(); }
    }

    // System.Text.Json replaces unpaired UTF-16 surrogates by default. Preserve the
    // caller's target identity by rejecting strings that cannot be sent to Rust exactly.
    internal static string? ValidateText(string? value)
    {
        if (value is null) return null;
        try { _ = StrictUtf8.GetByteCount(value); }
        catch (EncoderFallbackException) { throw InvalidUnicode(); }
        return value;
    }

    private static ActionDataException InvalidUnicode() =>
        new(ActionDataError.InvalidData, "Action data contains an unpaired Unicode surrogate.", null);

    private static void EnsureAbi()
    {
        if (Version() != 6) throw new InvalidOperationException("Unsupported native DesktopActions ABI.");
    }
    internal static byte[] ReadCatalog() { EnsureAbi(); return Copy(Catalog()); }
    internal static byte[] EvaluateTextInput(ReadOnlySpan<byte> bytes)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(TextInputEvaluate(data, (nuint)bytes.Length));
    }
    internal static byte[] Canonical(ReadOnlySpan<byte> bytes, bool envelope)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(Normalize(data, (nuint)bytes.Length, envelope ? 1u : 0u));
    }
    internal static byte[] NormalizeInput(ReadOnlySpan<byte> bytes)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(InputNormalize(data, (nuint)bytes.Length));
    }
    internal static byte[] NormalizeInputMetadata(ReadOnlySpan<byte> bytes, bool descriptor)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(InputMetadataNormalize(data, (nuint)bytes.Length, descriptor ? 1u : 0u));
    }
    internal static byte[] ReadPlan(ReadOnlySpan<byte> bytes, ActionPlatform platform)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(Plan(data, (nuint)bytes.Length, (uint)platform));
    }
    internal static byte[] ReadKindPlan(ReadOnlySpan<byte> identifier, ActionPlatform platform)
    {
        EnsureAbi();
        fixed (byte* data = identifier) return Copy(KindPlan(data, (nuint)identifier.Length, (uint)platform));
    }
    internal static byte[] ReadResult(ReadOnlySpan<byte> bytes, uint kind)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(ResultNormalize(data, (nuint)bytes.Length, kind));
    }
    internal static byte[] CreateError(ReadOnlySpan<byte> bytes)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(ErrorCreate(data, (nuint)bytes.Length));
    }
    internal static byte[] CreateExecutionReport(ReadOnlySpan<byte> bytes)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return Copy(ExecutionReportCreate(data, (nuint)bytes.Length));
    }
    private static byte[] Copy(JsonHandle owner)
    {
        using (owner)
        {
            if (owner.IsInvalid) throw new InvalidOperationException("Native JSON owner is unavailable.");
            var view = View(owner);
            if (view.Data == null) throw new InvalidOperationException("Native JSON bytes are unavailable.");
            // Foreign storage cannot escape its SafeHandle lifetime.
            var bytes = new ReadOnlySpan<byte>(view.Data, checked((int)view.Length)).ToArray();
            if (view.Code != 0) throw new ActionDataException((ActionDataError)view.Code,
                Encoding.UTF8.GetString(bytes), view.HasVersion == 0 ? null : view.Version);
            return bytes;
        }
    }
    [DllImport(Library, EntryPoint = "desktop_actions_abi_version")] private static extern uint Version();
    [DllImport(Library, EntryPoint = "desktop_actions_catalog")] private static extern JsonHandle Catalog();
    [DllImport(Library, EntryPoint = "desktop_actions_text_input_evaluate")] private static extern JsonHandle TextInputEvaluate(byte* data, nuint length);
    [DllImport(Library, EntryPoint = "desktop_actions_action_normalize")] private static extern JsonHandle Normalize(byte* data, nuint length, uint envelope);
    [DllImport(Library, EntryPoint = "desktop_actions_input_normalize")] private static extern JsonHandle InputNormalize(byte* data, nuint length);
    [DllImport(Library, EntryPoint = "desktop_actions_input_metadata_normalize")] private static extern JsonHandle InputMetadataNormalize(byte* data, nuint length, uint kind);
    [DllImport(Library, EntryPoint = "desktop_actions_action_plan")] private static extern JsonHandle Plan(byte* data, nuint length, uint platform);
    [DllImport(Library, EntryPoint = "desktop_actions_action_kind_plan")] private static extern JsonHandle KindPlan(byte* data, nuint length, uint platform);
    [DllImport(Library, EntryPoint = "desktop_actions_result_normalize")] private static extern JsonHandle ResultNormalize(byte* data, nuint length, uint kind);
    [DllImport(Library, EntryPoint = "desktop_actions_error_create")] private static extern JsonHandle ErrorCreate(byte* data, nuint length);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_report_create")] private static extern JsonHandle ExecutionReportCreate(byte* data, nuint length);
    [DllImport(Library, EntryPoint = "desktop_actions_json_view")] private static extern DesktopActionsJsonView View(JsonHandle owner);
    [DllImport(Library, EntryPoint = "desktop_actions_json_destroy")] internal static extern void Destroy(nint owner);
}

internal sealed class JsonHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public JsonHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.Destroy(handle); return true; }
}
