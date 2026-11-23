//! Windows effects and keyboard transaction recovery. Shared action planning,
//! result reduction and execution capacity remain in the desktop-actions core.
#[cfg(windows)]
mod desktop;
#[cfg(any(windows, test))]
mod input;
#[cfg(any(windows, test))]
mod target;
#[cfg(windows)]
pub use desktop::{ForegroundTarget, execute, execute_for_target};
