using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using NaviApps.DesktopActions;
using NaviApps.WindowManagement;

internal static class Program
{
    private static readonly JsonSerializerOptions ResultJson = new() { WriteIndented = true };
    private sealed record TargetKey(uint VirtualKey, byte Modifiers, bool Extended);
    private sealed record TargetState(ulong Handle, uint Process, uint Thread, string Text, TargetKey[] Keys,
        ulong CloseWindow, int CloseRequests, uint SelectionStart, uint SelectionEnd, bool EditFocused);
    private sealed record FolderCloseAttempt(long ElapsedMilliseconds)
    {
        public string Outcome { get; set; } = "requesting";
    }
    private const byte ControlModifier = 2;
    private const uint FocusEditMessage = 0x8000 + 2;
    private const uint AbortIfHungOrDestroyed = 0x0002 | 0x0020;
    private const long FolderCloseRetryMilliseconds = 2000;
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint process);
    [StructLayout(LayoutKind.Sequential)] private struct KeyInput { public ushort Vk, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct Input
    {
        [FieldOffset(0)] public uint Type; [FieldOffset(8)] public KeyInput Key;
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private delegate bool EnumWindowCallback(nint handle, nint parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, nint parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint handle, out uint process);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint handle);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern nint SendMessageTimeoutW(nint window, uint message, nuint wParam,
        nint lParam, uint flags, uint timeout, out nuint result);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint handle);
    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1838:Avoid StringBuilder parameters for P/Invokes", Justification = "This owned inspection fixture uses bounded Win32 text buffers; preserve its existing marshalling contract.")]
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(nint handle, System.Text.StringBuilder value, int maximum);
    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1838:Avoid StringBuilder parameters for P/Invokes", Justification = "This owned inspection fixture uses bounded Win32 text buffers; preserve its existing marshalling contract.")]
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(nint handle, System.Text.StringBuilder value, int maximum);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint handle);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint handle, out NativeRect rect);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] input, int size);
    [DllImport("user32.dll")] private static extern nint SetThreadDpiAwarenessContext(nint context);
    [DllImport("user32.dll")] private static extern bool PrintWindow(nint handle, nint destination, uint flags);
    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(in Guid id, uint flags, nint token, out nint path);

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 3 && args[0] == "--protocol") { File.WriteAllText(args[1], args[2]); return 0; }
        if (args.Length != 1) throw new ArgumentException("Provide an owned output directory.");
        var artifacts = Environment.GetEnvironmentVariable("VM_RUNNER_ARTIFACTS_DIR");
        var legacyArtifacts = Environment.GetEnvironmentVariable("NAVI_CI_ARTIFACTS");
        if (artifacts is not null && legacyArtifacts is not null && artifacts != legacyArtifacts)
            throw new InvalidOperationException("Conflicting VM Runner artifact directories.");
        artifacts ??= legacyArtifacts;
        if (!string.IsNullOrEmpty(artifacts) && !Path.IsPathFullyQualified(artifacts))
            throw new InvalidOperationException("VM_RUNNER_ARTIFACTS_DIR must be an absolute path.");
        Run(Path.GetFullPath(args[0]), !string.IsNullOrEmpty(artifacts)).GetAwaiter().GetResult();
        return 0;
    }
    private static async Task Run(string output, bool captureDesktopOnFailure)
    {
        Directory.CreateDirectory(output);
        var executable = Path.Combine(AppContext.BaseDirectory, "test_owned_input_target.exe");
        Require(File.Exists(executable), "The owned x64 Rust desktop target is required.");
        await using var state = new TargetConnection();
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        start.ArgumentList.Add("--target"); start.ArgumentList.Add(state.Name);
        using var child = Process.Start(start) ?? throw new InvalidOperationException("Cannot start owned input target.");
        var steps = new List<string>();
        var shellTransitions = new List<object>();
        WindowSnapshot? explorer = null;
        var ownedFolderName = "owned-folder-" + Guid.NewGuid().ToString("N");
        var ownedFolder = Path.Combine(output, ownedFolderName);
        var folderCloseClock = new Stopwatch();
        var folderCloseAttempts = new List<FolderCloseAttempt>(2);
        var checkingOwnedFolder = false;
        bool RequestOwnedFolderClose(WindowSnapshot window)
        {
            var elapsed = folderCloseClock.ElapsedMilliseconds;
            if (folderCloseAttempts.Count == 2 || (folderCloseAttempts.Count != 0
                && elapsed - folderCloseAttempts[^1].ElapsedMilliseconds < FolderCloseRetryMilliseconds)
                || !IsOwnedFolderWindow(window)) return false;

            var attempt = new FolderCloseAttempt(elapsed);
            folderCloseAttempts.Add(attempt);
            try
            {
                WindowsDesktop.RequestClose(window.Identity);
                attempt.Outcome = "queued";
                return true;
            }
            catch (WindowOperationException error)
            {
                attempt.Outcome = $"{error.Code} ({error.NativeCode})";
                if (folderCloseAttempts.Count == 2 && !HasNativeWindowIdentity(window.Identity)) return false;
                throw;
            }
        }
        try
        {
            await Wait(() => child.HasExited || state.IsReady, "owned target startup");
            Require(!child.HasExited, "The owned input target exited before reporting readiness.");
            var target = state.Read(); Require(target.Process == child.Id, "Wrong owned target PID.");
            var identity = new WindowIdentity(target.Handle, target.Process, target.Thread);
            await Focus(identity);
            foreach (var key in new[] { 0x10, 0x11, 0x12, 0x5b, 0x5c }) Require(GetAsyncKeyState(key) >= 0, "A modifier was already pressed in the fixture desktop.");
            async Task Execute(string identifier, string? input = null)
            {
                await Focus(identity);
                if (!state.Read().EditFocused)
                {
                    var handle = unchecked((nint)identity.Handle);
                    Require(SendMessageTimeoutW(handle, FocusEditMessage, 0, 0, AbortIfHungOrDestroyed,
                        1000, out var focused) != 0 && focused == 1,
                        "The restored owned window could not focus its native edit control.");
                }
                await Wait(() => state.Read().EditFocused, "owned native edit focus");
                var action = input is null ? ActionRequest.Create(identifier) : ActionRequest.Create(identifier, JsonSerializer.SerializeToElement(input));
                var result = await WindowsActionExecutor.ExecuteAsync(action);
                Require(result.FinalResult.Status == ActionResultStatus.Success, "Native action failed: " + result.ToJson());
                Require(result.Attempts.Count == 1 && result.Attempts[0].RequiredPermissions.Count == 0 && result.Attempts[0].DurationSeconds >= 0, "Native result metadata is inconsistent.");
            }
            async Task Shortcut(string value) => await Execute("action.keyboard.shortcut", value);
            async Task Text(string expected) => await Wait(() => state.Read().Text == expected, "target text " + expected);
            async Task Selection(string expected) => await Wait(() =>
            {
                var value = state.Read();
                return value.Text == expected && value.SelectionStart == 0 && value.SelectionEnd == expected.Length;
            }, "owned full edit selection");
            await Shortcut("ctrl+a"); await Selection("Before");
            await Shortcut("shift+a"); await Text("A");
            await Execute("action.editing.select-all"); await Selection("A");
            await Execute("action.editing.copy");
            await Shortcut("b"); await Text("b"); await Shortcut("ctrl+a");
            await Execute("action.editing.paste"); await Text("A");
            await Shortcut("ctrl+a"); await Execute("action.editing.cut"); await Text("");
            // Undo a single deletion rather than relying on how the edit control groups cut/paste.
            await Execute("action.editing.undo"); await Text("A");
            await Execute("action.editing.redo");
            await Wait(() => state.Read().Keys.Any(key => key.VirtualKey == 0x59 && key.Modifiers == ControlModifier), "Control-Y native redo input");
            await Shortcut("ctrl+page-down");
            await Wait(() => state.Read().Keys.Any(key => key.VirtualKey == 0x22 && key.Modifiers == ControlModifier && key.Extended), "extended physical PageDown input");
            steps.Add("separate-process physical typing and native select all/copy/paste/cut/undo; Control-Y and extended PageDown observed");

            await Focus(identity); Press(0xa2, false);
            try
            {
                await Wait(() => GetAsyncKeyState(0x11) < 0, "owned held Control");
                await Execute("action.editing.copy");
                Require(GetAsyncKeyState(0x11) < 0, "SDK released an already-held Control key.");
            }
            finally { Press(0xa2, true); }
            await Wait(() => GetAsyncKeyState(0x11) >= 0, "owned Control release");
            var beforeShift = state.Read().Keys.Length; Press(0xa0, false);
            try
            {
                // A delayed prior Control event can increase the count before this Shift arrives.
                await Wait(() => GetAsyncKeyState(0x10) < 0 && state.Read().Keys.Skip(beforeShift).Any(key => key.VirtualKey == 0x10 && key.Modifiers == 1), "owned target acknowledged held Shift");
                var before = state.Read().Keys.Length;
                var result = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.editing.copy"));
                Require(result.FinalResult.Error?.Code == ActionErrorCode.Busy, "Unexpected held modifier was ignored.");
                Require(state.Read().Keys.Length == before, "Rejected input posted a key.");
            }
            finally { Press(0xa0, true); }
            await Wait(() => GetAsyncKeyState(0x10) >= 0, "owned Shift release");
            steps.Add("already-held requested modifiers retained; conflicting modifiers rejected without injection");

            using (var cancellation = new CancellationTokenSource())
            {
                cancellation.Cancel(); var before = state.Read().Keys.Length;
                try { await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.editing.copy"), cancellation.Token); throw new InvalidOperationException("Cancelled input executed."); }
                catch (OperationCanceledException) { }
                Require(state.Read().Keys.Length == before, "Early cancellation performed input.");
            }
            var invalid = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.workspace.open-url", JsonSerializer.SerializeToElement("relative/path")));
            Require(invalid.FinalResult.Error?.Code == ActionErrorCode.InvalidInput, "Shared invalid URL did not fail before effects.");
            var unavailable = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.system.sleep-mac"));
            Require(unavailable.FinalResult.Error?.Code == ActionErrorCode.UnsupportedAction, "Unsupported action reported success.");
            steps.Add("early cancellation, invalid input and unavailable platform operations produce no success claim");

            await Focus(identity);
            var beforeDesktopKeys = state.Read().Keys.Length;
            // Exercise separate user-paced Shell interactions. Neither HRESULT
            // nor IsIconic is an animation-completion signal; native SDK-header
            // controls also lose rapid toggles. This cadence belongs only to the
            // fixture, not to the SDK's accepted-request contract.
            const int shellInteractionInterval = 1000;
            await Task.Delay(shellInteractionInterval);
            for (var cycle = 0; cycle < 3; cycle++)
            {
                var elapsed = Stopwatch.StartNew();
                JsonElement? showFinalResult = null, restoreFinalResult = null;
                var foregroundChanges = new List<object>(); var omittedForegroundChanges = 0;
                try
                {
                    shellTransitions.Add(Observe(identity, "before-show", cycle + 1, elapsed.Elapsed.TotalMilliseconds));
                    var show = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.system.show-desktop"));
                    showFinalResult = JsonSerializer.Deserialize<JsonElement>(show.FinalResult.ToJson());
                    Require(show.FinalResult.Status == ActionResultStatus.Success, "Show desktop request failed.");
                    await Wait(() => WindowsDesktop.GetWindow(identity).IsMinimized,
                        "native Show Desktop hid the owned window");
                    await Task.Delay(shellInteractionInterval);
                    shellTransitions.Add(Observe(identity, "before-restore", cycle + 1, elapsed.Elapsed.TotalMilliseconds));
                    var restore = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.system.show-desktop"));
                    restoreFinalResult = JsonSerializer.Deserialize<JsonElement>(restore.FinalResult.ToJson());
                    Require(restore.FinalResult.Status == ActionResultStatus.Success, "Show desktop restoration request failed.");
                    shellTransitions.Add(Observe(identity, "restore-input-accepted", cycle + 1, elapsed.Elapsed.TotalMilliseconds));
                    var previousForeground = GetForegroundWindow();
                    await Wait(() =>
                    {
                        var foreground = GetForegroundWindow();
                        if (foreground != previousForeground)
                        {
                            previousForeground = foreground;
                            if (foregroundChanges.Count < 64)
                                foregroundChanges.Add(Observe(identity, "restore-foreground-changed", cycle + 1, elapsed.Elapsed.TotalMilliseconds, foreground));
                            else omittedForegroundChanges++;
                        }
                        return !WindowsDesktop.GetWindow(identity).IsMinimized;
                    }, "owned window restored by Show Desktop");
                    await Task.Delay(shellInteractionInterval);
                }
                finally
                {
                    // Preserve the observation before owned recovery changes its meaning.
                    var beforeRecovery = Observe(identity, "before-recovery", cycle + 1, elapsed.Elapsed.TotalMilliseconds);
                    shellTransitions.Add(new
                    {
                        stage = "cycle-before-recovery",
                        cycle = cycle + 1,
                        elapsedMilliseconds = elapsed.Elapsed.TotalMilliseconds,
                        showFinalResult,
                        restoreFinalResult,
                        beforeRecovery,
                        foregroundChanges = foregroundChanges.ToArray(),
                        omittedForegroundChanges
                    });
                    // Recover only the owned target. Repeating a global toggle after
                    // an observation failure could undo a request already accepted.
                    if (WindowsDesktop.GetWindow(identity).IsMinimized) WindowsDesktop.Restore(identity);
                }
            }
            Require(state.Read().Keys.Length == beforeDesktopKeys, "Native desktop toggling injected input into the owned target.");
            steps.Add("three user-paced Show Desktop hide/restore cycles observed at a one-second interaction cadence; animation settings unchanged");

            var screenshotFolder = ScreenshotDirectory();
            var previousScreenshots = Directory.Exists(screenshotFolder)
                ? Directory.GetFiles(screenshotFolder, "*.png").ToHashSet(StringComparer.OrdinalIgnoreCase) : [];
            string? screenshot = null;
            try
            {
                await Execute("action.system.capture-screen-full");
                await Wait(() =>
                {
                    if (!Directory.Exists(screenshotFolder)) return false;
                    foreach (var path in Directory.GetFiles(screenshotFolder, "*.png"))
                    {
                        if (previousScreenshots.Contains(path)) continue;
                        try
                        {
                            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);
                            using var image = Image.FromStream(stream);
                            if (image.Width <= 0 || image.Height <= 0) continue;
                            screenshot = path; return true;
                        }
                        catch (IOException) { }
                        catch (ArgumentException) { }
                        catch (OutOfMemoryException) { }
                    }
                    return false;
                }, "Windows saved a decodable full-screen image in its known folder");
                steps.Add("full-screen capture saved a new image in the configured Windows Screenshots folder");
            }
            finally
            {
                if (screenshot is not null) await Wait(() =>
                {
                    try { File.Delete(screenshot); return true; } catch (UnauthorizedAccessException) { return false; }
                }, "owned screenshot cleanup");
            }

            await Focus(identity);
            var screens = WindowsDesktop.GetDisplays(); var original = WindowsDesktop.GetWindow(identity).Frame;
            var request = new WindowPlacementRequest(WindowPlacement.Grid(2, 1, 0, 0), inset: 6);
            var expected = Geometry.ResolvePlacement(request, original, screens.ToArray())!.Value;
            var placement = await WindowsActionExecutor.ExecuteAsync(ActionRequest.PlaceWindow(request));
            Require(placement.FinalResult.Status == ActionResultStatus.Success && Nearly(WindowsDesktop.GetWindow(identity).Frame, expected), "Window action did not use shared native resolution.");
            var beforeMissing = WindowsDesktop.GetWindow(identity).Frame;
            var missing = await WindowsActionExecutor.ExecuteAsync(ActionRequest.PlaceWindow(new(WindowPlacement.Fill, DisplayTarget.DisplayIdentifier(ulong.MaxValue))));
            Require(missing.FinalResult.Error?.Code == ActionErrorCode.NotFound && WindowsDesktop.GetWindow(identity).Frame == beforeMissing, "Missing display changed the focused window.");
            var movement = await WindowsActionExecutor.ExecuteAsync(ActionRequest.MoveWindow(new(DisplayCycleDirection.Next)));
            Require(movement.FinalResult.Status == ActionResultStatus.Success, "Window movement action failed.");
            steps.Add("window placement/movement delegates to WindowManagement; missing target reports failure without movement");

            await Execute("action.window.minimize");
            await Wait(() => WindowsDesktop.GetWindow(identity).IsMinimized, "owned focused-window minimization");
            WindowsDesktop.Restore(identity);
            await Wait(() => !WindowsDesktop.GetWindow(identity).IsMinimized, "owned minimize fixture recovery");
            await Focus(identity);
            steps.Add("focused-window minimization observed, then owned target restored without an automatic action retry");

            var scheme = "navi-actions-test-" + Guid.NewGuid().ToString("N");
            var protocolPath = Path.Combine(output, "protocol-" + Guid.NewGuid().ToString("N") + ".txt");
            var registryPath = "Software\\Classes\\" + scheme;
            Require(Registry.CurrentUser.OpenSubKey(registryPath) is null, "Fixture protocol already exists.");
            try
            {
                using (var registration = Registry.CurrentUser.CreateSubKey(registryPath))
                {
                    registration.SetValue("", "Owned SDK acceptance protocol"); registration.SetValue("URL Protocol", "");
                    using var command = registration.CreateSubKey("shell\\open\\command");
                    command.SetValue("", $"\"{Environment.GetEnvironmentVariable("DOTNET_BIN")}\" \"{typeof(Program).Assembly.Location}\" --protocol \"{protocolPath}\" \"%1\"");
                }
                var uri = scheme + ":owned-payload";
                var result = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.workspace.open-url", JsonSerializer.SerializeToElement(uri)));
                Require(result.FinalResult.Status == ActionResultStatus.Success, "Owned protocol launch failed: " + result.ToJson());
                await Wait(() => File.Exists(protocolPath) && File.ReadAllText(protocolPath) == uri, "owned protocol acknowledgement");
                Require(File.ReadAllText(protocolPath) == uri, "Shell altered the protocol payload.");
            }
            finally { Registry.CurrentUser.DeleteSubKeyTree(registryPath, throwOnMissingSubKey: false); }
            File.Delete(protocolPath);
            steps.Add("owned URI handler receives the exact URL through an owned STA shell worker; registration removed");

            await using var launchState = new TargetConnection();
            var previous = Environment.GetEnvironmentVariable("NAVI_ACTION_FIXTURE_PIPE");
            Process? launched = null;
            try
            {
                Environment.SetEnvironmentVariable("NAVI_ACTION_FIXTURE_PIPE", launchState.Name);
                var result = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.workspace.launch-application", JsonSerializer.SerializeToElement(executable)));
                Require(result.FinalResult.Status == ActionResultStatus.Success, "Explicit native executable launch failed.");
                await Wait(() => launchState.IsReady, "launched owned application");
                var ready = launchState.Read();
                var candidate = Process.GetProcessById((int)ready.Process);
                try
                {
                    _ = candidate.SafeHandle;
                    var thread = GetWindowThreadProcessId(unchecked((nint)ready.Handle), out var process);
                    Require(candidate.Id != child.Id && process == ready.Process && thread == ready.Thread
                        && string.Equals(candidate.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase),
                        "Launched process is not the owned executable.");
                    launched = candidate;
                }
                finally
                {
                    if (launched is null) candidate.Dispose();
                }
                WindowsDesktop.RequestClose(new(ready.Handle, ready.Process, ready.Thread));
                Require(launched.WaitForExit(10_000), "Owned launched application did not close.");
            }
            finally
            {
                Environment.SetEnvironmentVariable("NAVI_ACTION_FIXTURE_PIPE", previous);
                if (launched is not null) { if (!launched.HasExited) launched.Kill(entireProcessTree: true); launched.Dispose(); }

            }
            steps.Add("explicit .exe launched without shell arguments; exact owned process identity checked and closed");

            checkingOwnedFolder = true;
            folderCloseClock.Start();
            Directory.CreateDirectory(ownedFolder);
            // Include hidden windows so the fixture never closes a reused Explorer window.
            var beforeFolders = new HashSet<ulong>();
            Require(EnumWindows((handle, _) => { beforeFolders.Add(unchecked((ulong)handle)); return true; }, 0),
                "Cannot capture top-level window handles before opening the owned folder.");
            var folder = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.workspace.open-folder", JsonSerializer.SerializeToElement(ownedFolder)));
            Require(folder.FinalResult.Status == ActionResultStatus.Success, "Owned folder open failed.");
            await Wait(() =>
            {
                // Explorer appends a localized application name to its native window caption.
                var candidates = WindowsDesktop.GetWindows().Where(w => !beforeFolders.Contains(w.Identity.Handle)
                    && (w.Title == ownedFolderName || w.Title.StartsWith(ownedFolderName + " - ", StringComparison.Ordinal))
                    && IsOwnedFolderWindow(w)).Take(2).ToArray();
                if (candidates.Length != 1) return false;
                explorer = candidates[0];
                return true;
            }, "owned folder window");
            var ownedWindow = explorer!;
            Require(RequestOwnedFolderClose(ownedWindow), "The owned folder window changed before its first close request.");
            await Wait(() =>
            {
                if (!HasNativeWindowIdentity(ownedWindow.Identity)) return true;
                _ = RequestOwnedFolderClose(ownedWindow);
                return false;
            }, "owned folder close");
            checkingOwnedFolder = false;
            steps.Add("owned absolute folder opened and its newly created unique window closed");

            // A second window rejects its first ordinary close, like a cancelled save prompt.
            // Both windows share one process; closing either must never become process termination.
            await Shortcut("ctrl+n");
            await Wait(() => state.Read().CloseWindow != 0, "owned secondary window");
            var secondary = WindowsDesktop.GetWindows().Single(w => w.Identity.Handle == state.Read().CloseWindow);
            Require(secondary.Identity.ProcessId == identity.ProcessId, "Secondary window must share the owned process.");
            var preservedText = state.Read().Text;
            var closeRequest = ActionRequest.Create("action.window.close");
            await Focus(identity);
            using (var captured = WindowsActionExecutor.CaptureForegroundTarget()
                ?? throw new InvalidOperationException("Cannot capture the owned foreground window."))
            {
                await Focus(secondary.Identity);
                var stale = await WindowsActionExecutor.ExecuteForTargetAsync(closeRequest, captured);
                Require(stale.FinalResult.Error?.Code == ActionErrorCode.NativeFailed, "A different window in the same process was treated as the captured target.");
                Require(state.Read().CloseRequests == 0 && !child.HasExited, "A stale target requested a close.");
            }
            await Focus(secondary.Identity);
            Task<ActionExecutionReport> pendingClose;
            using (var captured = WindowsActionExecutor.CaptureForegroundTarget()
                ?? throw new InvalidOperationException("Cannot capture the owned secondary window."))
            {
                pendingClose = WindowsActionExecutor.ExecuteForTargetAsync(closeRequest, captured);
            }
            var refused = await pendingClose;
            Require(refused.FinalResult.Status == ActionResultStatus.Success, "Native close request was not accepted.");
            await Wait(() => state.Read().CloseRequests == 1, "owned close refusal");
            Require(!child.HasExited && WindowsDesktop.GetWindow(secondary.Identity).Identity == secondary.Identity, "Refused close must leave its window and process alive.");
            Require(state.Read().Text == preservedText, "Refused close changed owned input.");
            await Focus(secondary.Identity);
            var accepted = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.window.close"));
            Require(accepted.FinalResult.Status == ActionResultStatus.Success, "Second ordinary close failed.");
            await Wait(() => !WindowsDesktop.GetWindows().Any(w => w.Identity == secondary.Identity), "owned secondary close");
            Require(!child.HasExited && WindowsDesktop.GetWindow(identity).Identity == identity, "Single-window close must leave the sibling window and process alive.");
            Require(state.Read().Text == preservedText, "Single-window close changed sibling input.");
            steps.Add("captured target rejected the sibling window and a guarded run kept its own snapshot; ordinary close preserved the sibling window");

            await Focus(identity);
            Capture(identity, WindowsDesktop.GetWindow(identity).Frame, Path.Combine(output, "owned-input-target.png"));
            var close = await WindowsActionExecutor.ExecuteAsync(ActionRequest.Create("action.window.close"));
            Require(close.FinalResult.Status == ActionResultStatus.Success && child.WaitForExit(10_000) && child.ExitCode == 0, "Owned foreground close was not observed.");
            steps.Add("foreground window close is an ordinary native request; application-wide quit is unavailable on Windows");
            File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new
            {
                status = "passed",
                architecture = RuntimeInformation.OSArchitecture.ToString(),
                os = Environment.OSVersion.VersionString,
                targetProcess = target.Process,
                steps,
                screenCount = screens.Count,
            }, ResultJson));
            Console.WriteLine("DesktopActions owned native cross-process acceptance passed.");
        }
        catch (Exception error)
        {
            if (state.Latest is { } failure)
            {
                Console.WriteLine("Owned target state: " + JsonSerializer.Serialize(failure));
                var current = checkingOwnedFolder
                    ? ObserveOwnedFolderClose(explorer, folderCloseAttempts)
                    : Observe(new(failure.Handle, failure.Process, failure.Thread), "failure");
                File.WriteAllText(Path.Combine(output, "failure.json"), JsonSerializer.Serialize(new { error = error.GetType().Name, message = error.Message, target = failure, shellTransitions, current }));
                // Whole-desktop failure images belong only to the explicitly owned CI guest.
                if (captureDesktopOnFailure)
                {
                    try
                    {
                        var bounds = SystemInformation.VirtualScreen; using var image = new Bitmap(bounds.Width, bounds.Height); using var graphics = Graphics.FromImage(image);
                        graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size); image.Save(Path.Combine(output, "failure-desktop.png"), System.Drawing.Imaging.ImageFormat.Png);
                    }
                    catch (Exception diagnostic) { File.WriteAllText(Path.Combine(output, "capture-error.txt"), diagnostic.Message); }
                }
            }
            throw;
        }
        finally
        {
            if (checkingOwnedFolder && explorer is { } window) { try { _ = RequestOwnedFolderClose(window); } catch (WindowOperationException) { } }
            if (!child.HasExited) { _ = child.CloseMainWindow(); if (!child.WaitForExit(5000)) child.Kill(entireProcessTree: true); }
            if (Directory.Exists(ownedFolder)) Directory.Delete(ownedFolder);
        }
    }
    // A coalesced, current-user-only pipe carries immutable snapshots. The UI
    // thread never performs file/pipe I/O, and a disconnected child fails promptly.
    private sealed class TargetConnection : IAsyncDisposable
    {
        public string Name { get; } = "navi-actions-target-" + Guid.NewGuid().ToString("N");
        private readonly NamedPipeServerStream server;
        private readonly CancellationTokenSource cancellation = new();
        private readonly Task reader;
        private TargetState? latest;
        public TargetState? Latest => Volatile.Read(ref latest);
        public bool IsReady { get { CheckConnection(); return Latest is not null; } }
        public TargetConnection()
        {
            server = new(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            reader = Receive();
        }
        private async Task Receive()
        {
            await server.WaitForConnectionAsync(cancellation.Token);
            if (GetNamedPipeClientProcessId(server.SafePipeHandle, out var peer) == 0 || peer == 0)
                throw new InvalidDataException("Cannot identify the owned target pipe peer.");
            using var stream = new StreamReader(server, leaveOpen: true);
            while (await stream.ReadLineAsync(cancellation.Token) is { } line)
            {
                if (line.Length > 65536) throw new InvalidDataException("Owned target snapshot exceeds its bound.");
                var snapshot = JsonSerializer.Deserialize<TargetState>(line) ?? throw new InvalidDataException("Empty target snapshot.");
                if (snapshot.Process != peer || snapshot.Handle == 0 || snapshot.Thread == 0)
                    throw new InvalidDataException("The target snapshot differs from the owned pipe peer.");
                Volatile.Write(ref latest, snapshot);
            }
        }
        private void CheckConnection()
        {
            if (reader.IsFaulted) throw new InvalidOperationException("Owned target channel failed.", reader.Exception);
            if (reader.IsCompleted) throw new InvalidOperationException("Owned target disconnected before acknowledgement.");
        }
        public TargetState Read() { CheckConnection(); return Latest ?? throw new InvalidOperationException("Owned target has not reported state."); }
        public async ValueTask DisposeAsync()
        {
            cancellation.Cancel(); server.Dispose();
            try { await reader; }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch (ObjectDisposedException) when (cancellation.IsCancellationRequested) { }
            catch (IOException) when (cancellation.IsCancellationRequested) { }
            finally { cancellation.Dispose(); }
        }
    }
    private static async Task Focus(WindowIdentity identity)
    {
        var handle = unchecked((nint)identity.Handle); _ = SetForegroundWindow(handle);
        await Wait(() => GetForegroundWindow() == handle, "owned foreground window");
        var thread = GetWindowThreadProcessId(handle, out var process);
        Require(thread == identity.ThreadId && process == identity.ProcessId, "Owned foreground identity changed.");
    }
    private static bool HasNativeWindowIdentity(WindowIdentity identity)
    {
        var thread = GetWindowThreadProcessId(unchecked((nint)identity.Handle), out var process);
        return thread != 0 && thread == identity.ThreadId && process == identity.ProcessId;
    }
    private static bool IsOwnedFolderWindow(WindowSnapshot window)
    {
        var identity = window.Identity;
        if (!HasNativeWindowIdentity(identity)) return false;
        var handle = unchecked((nint)identity.Handle);
        var windowClass = new System.Text.StringBuilder(256);
        var title = new System.Text.StringBuilder(1024);
        if (GetClassNameW(handle, windowClass, windowClass.Capacity) == 0
            || windowClass.ToString() != "CabinetWClass" || GetWindowTextW(handle, title, title.Capacity) == 0) return false;
        return title.ToString() == window.Title && HasNativeWindowIdentity(identity);
    }
    private static object ObserveOwnedFolderClose(WindowSnapshot? window, List<FolderCloseAttempt> attempts)
    {
        var identity = window?.Identity;
        var sameOwner = identity is { } selected && HasNativeWindowIdentity(selected);
        var handle = unchecked((nint)identity.GetValueOrDefault().Handle);
        return new
        {
            stage = "owned-folder-close",
            selected = identity,
            selectedTitle = window?.Title,
            sameOwner,
            sameFolder = window is not null && IsOwnedFolderWindow(window),
            isForeground = sameOwner && GetForegroundWindow() == handle,
            visible = sameOwner && IsWindowVisible(handle),
            attempts
        };
    }
    private static object Observe(WindowIdentity identity, string stage, int? cycle = null, double? elapsedMilliseconds = null, nint? foregroundWindow = null)
    {
        var foreground = foregroundWindow ?? GetForegroundWindow();
        var thread = GetWindowThreadProcessId(foreground, out var process);
        var name = new System.Text.StringBuilder(256); _ = GetClassNameW(foreground, name, 256);
        var title = new System.Text.StringBuilder(1024); _ = GetWindowTextW(foreground, title, 1024);
        var hasRect = GetWindowRect(foreground, out var rect);
        return new
        {
            stage,
            cycle,
            elapsedMilliseconds,
            nativeMinimized = IsIconic(unchecked((nint)identity.Handle)),
            foreground = foreground.ToInt64(),
            foregroundProcess = process,
            foregroundThread = thread,
            foregroundTitle = title.ToString(),
            foregroundClass = name.ToString(),
            foregroundVisible = IsWindowVisible(foreground),
            foregroundRect = hasRect ? new { left = rect.Left, top = rect.Top, right = rect.Right, bottom = rect.Bottom } : null,
            leftWin = GetAsyncKeyState(0x5b),
            rightWin = GetAsyncKeyState(0x5c),
            dKey = GetAsyncKeyState(0x44)
        };
    }
    private static string ScreenshotDirectory()
    {
        var id = new Guid("b7bede81-df94-4682-a7d8-57a52620b86f");
        Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(in id, 0x4000, 0, out var path));
        try { return Marshal.PtrToStringUni(path) ?? throw new InvalidOperationException("Screenshots known folder is unavailable."); }
        finally { Marshal.FreeCoTaskMem(path); }
    }
    private static void Press(ushort key, bool up)
    {
        var events = new[] { new Input { Type = 1, Key = new KeyInput { Vk = key, Flags = up ? 2u : 0u } } };
        Require(SendInput(1, events, Marshal.SizeOf<Input>()) == 1, "Fixture-owned key state injection failed.");
    }
    private static async Task Wait(Func<bool> predicate, string stage)
    {
        var start = Stopwatch.StartNew();
        while (start.Elapsed < TimeSpan.FromSeconds(10))
        {
            try { if (predicate()) return; } catch (IOException) { }
            await Task.Delay(25);
        }
        throw new TimeoutException(stage);
    }
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static bool Nearly(Rect a, Rect b) => Math.Abs(a.X - b.X) <= 1 && Math.Abs(a.Y - b.Y) <= 1 && Math.Abs(a.Width - b.Width) <= 1 && Math.Abs(a.Height - b.Height) <= 1;
    private static void Capture(WindowIdentity identity, Rect frame, string path)
    {
        var previous = SetThreadDpiAwarenessContext(new nint(-4)); Require(previous != 0, "Cannot scope capture DPI.");
        try
        {
            using var image = new Bitmap(checked((int)frame.Width), checked((int)frame.Height)); using var graphics = Graphics.FromImage(image);
            var dc = graphics.GetHdc(); try { Require(PrintWindow(unchecked((nint)identity.Handle), dc, 0), "Owned input target capture failed."); } finally { graphics.ReleaseHdc(dc); }
            image.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        finally { _ = SetThreadDpiAwarenessContext(previous); }
    }
}
