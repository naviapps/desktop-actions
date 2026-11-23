using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NaviApps.DesktopActions;

[StructLayout(LayoutKind.Sequential)]
internal struct DesktopActionsSequenceSummary
{
    internal uint Status, AllActionsSucceeded;
    internal nuint RecordedCount;
}

internal static partial class Native
{
    internal static ActionSequenceHandle CreateSequence(int count, ActionSequenceFailureBehavior behavior)
    { EnsureAbi(); return SequenceCreate(checked((nuint)count), (uint)behavior); }
    [DllImport(Library, EntryPoint = "desktop_actions_sequence_create")] private static extern ActionSequenceHandle SequenceCreate(nuint count, uint behavior);
    [DllImport(Library, EntryPoint = "desktop_actions_sequence_next")] internal static extern nuint NextSequence(ActionSequenceHandle sequence);
    [DllImport(Library, EntryPoint = "desktop_actions_sequence_record")] internal static extern uint RecordSequence(ActionSequenceHandle sequence, nuint id, uint result);
    [DllImport(Library, EntryPoint = "desktop_actions_sequence_cancel")] internal static extern void CancelSequence(ActionSequenceHandle sequence);
    [DllImport(Library, EntryPoint = "desktop_actions_sequence_summary")] internal static extern DesktopActionsSequenceSummary SummarizeSequence(ActionSequenceHandle sequence);
    [DllImport(Library, EntryPoint = "desktop_actions_sequence_destroy")] internal static extern void DestroySequence(nint sequence);
}

internal sealed class ActionSequenceHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    public ActionSequenceHandle() : base(true) { }
    protected override bool ReleaseHandle() { Native.DestroySequence(handle); return true; }
}
