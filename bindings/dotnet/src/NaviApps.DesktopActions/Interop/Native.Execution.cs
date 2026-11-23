using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace NaviApps.DesktopActions;

internal static unsafe partial class Native
{
    internal static WindowsRunHandle CreateWindows(ReadOnlySpan<byte> bytes)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return WindowsCreate(data, (nuint)bytes.Length);
    }
    internal static WindowsRunHandle CreateWindowsForTarget(ReadOnlySpan<byte> bytes, WindowsTargetHandle target)
    {
        EnsureAbi();
        fixed (byte* data = bytes) return WindowsCreateForTarget(data, (nuint)bytes.Length, target);
    }
    internal static WindowsTargetHandle CaptureWindowsTarget()
    { EnsureAbi(); return WindowsTargetCapture(); }
    internal static byte[] ExecuteWindows(WindowsRunHandle run) => Copy(WindowsExecute(run));
    internal static ExecutionPoolHandle CreatePool(int maximum, ulong timeout)
    { EnsureAbi(); return PoolCreate(checked((nuint)maximum), timeout); }
    [DllImport(Library, EntryPoint = "desktop_actions_windows_create")] private static extern WindowsRunHandle WindowsCreate(byte* data, nuint length);
    [DllImport(Library, EntryPoint = "desktop_actions_windows_create_for_target")] private static extern WindowsRunHandle WindowsCreateForTarget(byte* data, nuint length, WindowsTargetHandle target);
    [DllImport(Library, EntryPoint = "desktop_actions_windows_target_capture")] private static extern WindowsTargetHandle WindowsTargetCapture();
    [DllImport(Library, EntryPoint = "desktop_actions_windows_target_destroy")] internal static extern void DestroyWindowsTarget(nint target);
    [DllImport(Library, EntryPoint = "desktop_actions_windows_execute")] private static extern JsonHandle WindowsExecute(WindowsRunHandle run);
    [DllImport(Library, EntryPoint = "desktop_actions_windows_cancel")] internal static extern void CancelWindows(WindowsRunHandle run);
    [DllImport(Library, EntryPoint = "desktop_actions_windows_destroy")] internal static extern void DestroyWindows(nint run);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_create")] private static extern ExecutionPoolHandle PoolCreate(nuint maximum, ulong timeout);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_reserve")] internal static extern ulong Reserve(ExecutionPoolHandle pool, ulong now, uint exempt);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_deadline")] internal static extern ulong Deadline(ExecutionPoolHandle pool, ulong id);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_cancel")] internal static extern uint Cancel(ExecutionPoolHandle pool, ulong id, ulong now);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_timeout")] internal static extern uint Timeout(ExecutionPoolHandle pool, ulong id, ulong now);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_active")] internal static extern uint Active(ExecutionPoolHandle pool, ulong id);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_finish")] internal static extern uint Finish(ExecutionPoolHandle pool, ulong id, ulong now);
    [DllImport(Library, EntryPoint = "desktop_actions_execution_destroy")] internal static extern void DestroyPool(nint pool);
}
internal sealed class WindowsRunHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public WindowsRunHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.DestroyWindows(handle); return true; }
}
internal sealed class WindowsTargetHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public WindowsTargetHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.DestroyWindowsTarget(handle); return true; }
}
internal sealed class ExecutionPoolHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public ExecutionPoolHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.DestroyPool(handle); return true; }
}
