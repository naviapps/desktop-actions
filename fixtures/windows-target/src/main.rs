//! The separate Win32 input target used by the managed desktop acceptance fixture.

#[cfg(not(windows))]
fn main() {}

#[cfg(windows)]
fn main() -> std::io::Result<()> {
    target::run()
}

#[cfg(windows)]
mod target {
    use serde::Serialize;
    use std::{
        cell::{Cell, RefCell},
        env,
        fs::OpenOptions,
        io::{self, Write},
        ptr::{null, null_mut},
        sync::{Arc, Mutex, mpsc},
        thread,
    };
    use windows_sys::{
        Win32::{
            Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM},
            Graphics::Gdi::{COLOR_WINDOW, HBRUSH, UpdateWindow},
            System::{LibraryLoader::GetModuleHandleW, Pipes::WaitNamedPipeW},
            UI::{
                Controls::{EM_GETSEL, EM_SETLIMITTEXT, EM_SETSEL},
                HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext},
                Input::{
                    Ime::ImmAssociateContext,
                    KeyboardAndMouse::{
                        GetFocus, GetKeyState, SetFocus, VK_CONTROL, VK_MENU, VK_SHIFT,
                    },
                },
                WindowsAndMessaging::*,
            },
        },
        w,
    };

    const MAX_TEXT: usize = 4096;
    const MAX_KEYS: usize = 512;
    const PIPE_FAILED: u32 = WM_APP + 1;
    const FOCUS_EDIT: u32 = WM_APP + 2;
    const CONTROL: u8 = 2;

    #[derive(Clone, Copy, Serialize)]
    #[serde(rename_all = "PascalCase")]
    struct Key {
        virtual_key: usize,
        modifiers: u8,
        extended: bool,
    }

    #[derive(Serialize)]
    #[serde(rename_all = "PascalCase")]
    struct Snapshot {
        handle: usize,
        process: u32,
        thread: u32,
        text: String,
        keys: Vec<Key>,
        close_window: usize,
        close_requests: u32,
        selection_start: u32,
        selection_end: u32,
        edit_focused: bool,
    }

    struct State {
        main: HWND,
        edit: HWND,
        identity: (u32, u32),
        ready: Cell<bool>,
        secondary: Cell<HWND>,
        close_requests: Cell<u32>,
        keys: RefCell<Vec<Key>>,
        pending: Arc<Mutex<Option<Snapshot>>>,
        wake: mpsc::SyncSender<()>,
    }

    impl State {
        fn publish(&self) {
            if !self.ready.get() {
                return;
            }
            let mut text = [0; MAX_TEXT + 1];
            let mut start = 0u32;
            let mut end = 0u32;
            let (len, focused) = unsafe {
                let len = GetWindowTextW(self.edit, text.as_mut_ptr(), text.len() as i32);
                SendMessageW(
                    self.edit,
                    EM_GETSEL,
                    (&raw mut start) as WPARAM,
                    (&raw mut end) as LPARAM,
                );
                (len, GetFocus() == self.edit)
            };
            let value = Snapshot {
                handle: self.main as usize,
                process: self.identity.0,
                thread: self.identity.1,
                text: String::from_utf16_lossy(&text[..len as usize]),
                keys: self.keys.borrow().clone(),
                close_window: self.secondary.get() as usize,
                close_requests: self.close_requests.get(),
                selection_start: start,
                selection_end: end,
                edit_focused: focused,
            };
            *self
                .pending
                .lock()
                .expect("Only the owned writer uses the snapshot") = Some(value);
            let _ = self.wake.try_send(());
        }

        fn open_secondary(&self) -> io::Result<()> {
            let mut secondary = self.secondary.get();
            if secondary.is_null() {
                secondary = top_level(w!("DesktopActions owned close target"), 140, 140, 350, 240)?;
                unsafe {
                    SetWindowLongPtrW(secondary, GWLP_USERDATA, (self as *const Self) as isize)
                };
                self.secondary.set(secondary);
            }
            unsafe {
                ShowWindow(secondary, SW_SHOW);
                UpdateWindow(secondary);
                SetForegroundWindow(secondary);
            }
            Ok(())
        }
    }

    pub fn run() -> io::Result<()> {
        let mut args = env::args_os().skip(1);
        let channel = match (args.next(), args.next(), args.next(), args.next()) {
            (Some(mode), Some(pipe), None, None) if mode == "--target" => Some(pipe),
            (None, None, None, None) => env::var_os("NAVI_ACTION_FIXTURE_PIPE"),
            _ => None,
        };
        let name = channel
            .and_then(|value| value.into_string().ok())
            .filter(|value| {
                value
                    .strip_prefix("navi-actions-target-")
                    .is_some_and(|nonce| {
                        nonce.len() == 32
                            && nonce
                                .bytes()
                                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                    })
            })
            .ok_or_else(|| io::Error::other("Expected the owned desktop target pipe name."))?;
        let pipe = format!(r"\\.\pipe\{name}");
        let pipe_wide: Vec<_> = pipe.encode_utf16().chain([0]).collect();
        if unsafe { WaitNamedPipeW(pipe_wide.as_ptr(), 10_000) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut writer = OpenOptions::new().write(true).open(pipe)?;
        let main = unsafe {
            if SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).is_null() {
                return Err(io::Error::last_os_error());
            }
            if RegisterClassW(&WNDCLASSW {
                lpfnWndProc: Some(window_proc),
                hInstance: GetModuleHandleW(null()),
                hbrBackground: (COLOR_WINDOW + 1) as HBRUSH,
                lpszClassName: w!("DesktopActions.OwnedInputTarget"),
                ..WNDCLASSW::default()
            }) == 0
            {
                return Err(io::Error::last_os_error());
            }
            top_level(w!("DesktopActions owned input target"), 80, 80, 500, 360)?
        };

        let edit = unsafe {
            CreateWindowExW(
                WS_EX_CLIENTEDGE,
                w!("EDIT"),
                w!("Before"),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | (ES_MULTILINE | ES_AUTOVSCROLL) as u32,
                0,
                0,
                0,
                0,
                main,
                null_mut(),
                GetModuleHandleW(null()),
                null(),
            )
        };
        if edit.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut process = 0;
        let thread = unsafe { GetWindowThreadProcessId(main, &raw mut process) };
        if thread == 0 || process == 0 {
            return Err(io::Error::last_os_error());
        }
        let (wake, messages) = mpsc::sync_channel(1);
        let pending = Arc::new(Mutex::new(None::<Snapshot>));
        let state = Box::new(State {
            main,
            edit,
            identity: (process, thread),
            ready: Cell::new(false),
            secondary: Cell::new(null_mut()),
            close_requests: Cell::new(0),
            keys: RefCell::new(Vec::new()),
            pending: pending.clone(),
            wake,
        });
        let main_id = main as usize;
        thread::spawn(move || {
            while messages.recv().is_ok() {
                let snapshot = pending
                    .lock()
                    .expect("Only the owned UI publishes snapshots")
                    .take();
                if let Some(snapshot) = snapshot {
                    let result = serde_json::to_vec(&snapshot)
                        .map_err(io::Error::other)
                        .and_then(|mut bytes| {
                            bytes.push(b'\n');
                            writer.write_all(&bytes)
                        });
                    if result.is_err() {
                        unsafe { PostMessageW(main_id as HWND, PIPE_FAILED, 0, 0) };
                        break;
                    }
                }
            }
        });
        unsafe {
            SetWindowLongPtrW(main, GWLP_USERDATA, (&raw const *state) as isize);
            SendMessageW(edit, EM_SETLIMITTEXT, MAX_TEXT, 0);
            ImmAssociateContext(edit, null_mut());
            resize(&state);
            ShowWindow(main, SW_SHOW);
            UpdateWindow(main);
            SetForegroundWindow(main);
            SetFocus(edit);
        }
        state.ready.set(true);
        state.publish();

        let mut message = MSG::default();
        loop {
            match unsafe { GetMessageW(&raw mut message, null_mut(), 0, 0) } {
                -1 => return Err(io::Error::last_os_error()),
                0 => return Ok(()),
                _ => {}
            }
            if message.hwnd == main && message.message == PIPE_FAILED {
                return Err(io::Error::other(
                    "The owned desktop snapshot channel failed.",
                ));
            }
            if message.hwnd == edit && matches!(message.message, WM_KEYDOWN | WM_SYSKEYDOWN) {
                let modifiers = unsafe {
                    u8::from(GetKeyState(VK_SHIFT as i32) < 0)
                        | (u8::from(GetKeyState(VK_CONTROL as i32) < 0) << 1)
                        | (u8::from(GetKeyState(VK_MENU as i32) < 0) << 2)
                };
                let key = Key {
                    virtual_key: message.wParam,
                    modifiers,
                    extended: message.lParam & (1 << 24) != 0,
                };
                let mut keys = state.keys.borrow_mut();
                if keys.len() == MAX_KEYS {
                    return Err(io::Error::other(
                        "The owned desktop key observation limit was reached.",
                    ));
                }
                keys.push(key);
                drop(keys);
                if modifiers == CONTROL {
                    match message.wParam {
                        // The former WinForms TextBox handles delivered Ctrl+A this way.
                        // Let EDIT handle all clipboard and undo shortcuts normally.
                        0x41 => {
                            unsafe { SendMessageW(edit, EM_SETSEL, 0, -1) };
                            state.publish();
                            continue;
                        }
                        0x4e => {
                            state.open_secondary()?;
                            state.publish();
                            continue;
                        }
                        _ => {}
                    }
                }
            }
            unsafe {
                TranslateMessage(&raw const message);
                DispatchMessageW(&raw const message);
            }
            if message.hwnd == edit {
                state.publish();
            }
        }
    }

    fn top_level(title: *const u16, x: i32, y: i32, width: i32, height: i32) -> io::Result<HWND> {
        let window = unsafe {
            CreateWindowExW(
                0,
                w!("DesktopActions.OwnedInputTarget"),
                title,
                WS_OVERLAPPEDWINDOW,
                x,
                y,
                width,
                height,
                null_mut(),
                null_mut(),
                GetModuleHandleW(null()),
                null(),
            )
        };
        if window.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(window)
        }
    }

    unsafe fn resize(state: &State) {
        let mut client = RECT::default();
        unsafe {
            GetClientRect(state.main, &raw mut client);
            MoveWindow(state.edit, 0, 0, client.right, client.bottom, 1);
        }
    }

    unsafe extern "system" fn window_proc(
        window: HWND,
        message: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        let state = unsafe { (GetWindowLongPtrW(window, GWLP_USERDATA) as *const State).as_ref() };
        if let Some(state) = state {
            match (message, window == state.main) {
                (WM_SIZE, true) => unsafe { resize(state) },
                (WM_SETFOCUS, true) => unsafe {
                    SetFocus(state.edit);
                },
                (WM_ACTIVATE, true) => state.publish(),
                (WM_COMMAND, true) if lparam as HWND == state.edit => state.publish(),
                (FOCUS_EDIT, true) => {
                    // The shell can restore the top-level window without
                    // returning keyboard focus to its edit control.
                    if unsafe { GetForegroundWindow() != window || IsIconic(window) != 0 } {
                        return 0;
                    }
                    unsafe { SetFocus(state.edit) };
                    state.publish();
                    return LRESULT::from(unsafe { GetFocus() == state.edit });
                }
                (WM_GETMINMAXINFO, true) => {
                    let minimum = unsafe { &mut *(lparam as *mut MINMAXINFO) };
                    minimum.ptMinTrackSize.x = minimum.ptMinTrackSize.x.max(200);
                    minimum.ptMinTrackSize.y = minimum.ptMinTrackSize.y.max(150);
                    return 0;
                }
                (WM_CLOSE, false) => {
                    let count = state.close_requests.get() + 1;
                    state.close_requests.set(count);
                    state.publish();
                    if count == 1 {
                        return 0;
                    }
                }
                (WM_DESTROY, false) => {
                    state.secondary.set(null_mut());
                    state.publish();
                }
                (WM_DESTROY, true) => unsafe {
                    PostQuitMessage(0);
                },
                _ => {}
            }
        }
        unsafe { DefWindowProcW(window, message, wparam, lparam) }
    }
}
