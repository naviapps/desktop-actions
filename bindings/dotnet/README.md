# NaviApps.DesktopActions

.NET 10 bindings for Rust-backed action planning, codecs and bounded execution.
`WindowsActionExecutor` performs live effects on Windows. On macOS, the
[Swift macOS adapter](https://github.com/naviapps/desktop-actions/blob/main/docs/swift-macos.md)
performs native effects.

## Install

Download `desktop-actions-nuget-<revision>-<attempt>` from a successful
[SDK distribution run](https://github.com/naviapps/sdk-tooling/actions/workflows/check-sdk-distribution.yml)
for your selected revision. Verify each package against its SHA-256 receipt.
Put `NaviApps.DesktopActions` from the artifact root and its exact
`NaviApps.WindowManagement` dependency from `dependencies/` in the same local feed.
Keep the packages and runtime assets from the same build. The native ABI is 6.

The packages include native assets for macOS 26 or later on ARM64 and x64, and
Windows 11 x64. Use x64 .NET on Windows 11 ARM64.

In a new .NET 10 project directory, use the exact version in the package filename
and the absolute path to the local feed:

```sh
dotnet new console --framework net10.0 --no-restore
dotnet package add NaviApps.DesktopActions --version "[0.1.0]" --no-restore
dotnet restore --source "/absolute/path/to/sdk-packages" --packages .nuget-packages
```

Use a fresh cache whenever you switch candidates with the same version. Private
feeds must retain immutable package versions. Local packing and CI do not
publish or replace feed packages.

## Inspect an action

Put this example in `Program.cs` and run `dotnet run --no-restore`. It constructs
requests and inspects a plan without performing native effects.

```csharp
using NaviApps.DesktopActions;

var text = new ActionInput.Text("  https://example.com  ");
var open = ActionRequest.CreateWithInput("action.workspace.open-url", text);
var restoredText = ActionInput.FromJson(open.TypedInput!.ToJson());

var action = ActionRequest.Create("action.editing.copy");
var windows = action.Plan(ActionPlatform.Windows);
if (windows.Steps[0].Instruction is ActionMethod.KeyEvent key)
{
    Console.WriteLine(key.VirtualKeyCode);
}
```

`ActionPlanStep.Instruction` provides typed Rust plan values. Use
`ActionPlanStep.Method` for the owned wire JSON and `TypedExampleInput` on catalog
parameters for action construction. The catalog, text evaluation, text and
input-free request coding, and result codecs use source-generated JSON metadata.
Typed window inputs use the WindowManagement codecs. Result construction,
decoding and runner failure reporting work with `System.Text.Json` reflection
disabled.

For live effects, see the
[Windows guide](https://github.com/naviapps/desktop-actions/blob/main/docs/WINDOWS.md).
Hosts can opt into captured-foreground execution with
`WindowsActionExecutor.CaptureForegroundTarget` and `ExecuteForTargetAsync`.
The [SDK overview](https://github.com/naviapps/desktop-actions#saved-action-json)
describes saved data and migration.
