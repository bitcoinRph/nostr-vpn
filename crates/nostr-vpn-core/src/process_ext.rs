use std::process::Command;

pub trait CommandWindowExt {
    /// On Windows, prevent a console window from flashing when a console-subsystem
    /// binary is spawned from a GUI process. No-op on other platforms.
    fn hide_console_window(&mut self) -> &mut Self;
}

#[cfg(windows)]
impl CommandWindowExt for Command {
    fn hide_console_window(&mut self) -> &mut Self {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        self.creation_flags(CREATE_NO_WINDOW)
    }
}

#[cfg(not(windows))]
impl CommandWindowExt for Command {
    fn hide_console_window(&mut self) -> &mut Self {
        self
    }
}
