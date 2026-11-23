# SwiftUI action input controls

Compose standard action inputs with host-owned copy, drafts and native services.

## Overview

This optional product supplies `ActionTextInputField`, `ActionSelectionInput` and
`ActionShortcutMenu`. It also supplies standard SF Symbols through
`DesktopActions.ActionKind.standardSystemImage`. Hosts can override artwork.
The core `DesktopActions` product does not import SwiftUI or a native adapter.

Input kinds and forms come from the Rust catalog through `ActionKind.descriptor`
and `ActionTextInputKind`. Rust evaluates draft normalization, executable input,
Shortcut matching and supplied directory observations. Evaluation proposes a
confirmation without mutating the original draft or a saved action payload.

Hosts retain sheet/navigation state, focus, loading and error state, titles,
placeholders, hints, validation copy, accessibility identifiers, category ordering,
window templates and custom commands. Selection content and native picker commands
are injected. Mounting these views does not enumerate apps, run Shortcuts, present
panels, change permissions, persist input or execute an action.

Call `ActionTextInputKind.evaluate` to obtain normalized and confirmed values and a
portable issue code. A missing or empty Shortcut catalog allows manual entry.
Exact names take precedence; otherwise only a unique Unicode-lowercase match can
confirm. An ambiguous match requires an explicit selection. The supplied directory
callback receives only a nonempty normalized folder path. Platform availability
and input validity do not prove permission, target availability or effect success.
