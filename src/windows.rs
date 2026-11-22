use crate::{Error, ProcessKey, Result};
use std::{collections::HashMap, ffi::c_void, mem, path::Path};
use windows_sys::Win32::{
    Foundation::{CloseHandle, GetLastError, HANDLE, INVALID_HANDLE_VALUE},
    Storage::FileSystem::{MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH},
    System::{
        Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
        Threading::{
            GetExitCodeProcess, GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        },
    },
};

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

const ERROR_ACCESS_DENIED: u32 = 5;
const ERROR_INVALID_PARAMETER: u32 = 87;

pub fn process_key(pid: u32) -> Result<Option<ProcessKey>> {
    query(pid, false)
}

fn query(pid: u32, denied_is_gone: bool) -> Result<Option<ProcessKey>> {
    let raw = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if raw.is_null() {
        return match unsafe { GetLastError() } {
            ERROR_INVALID_PARAMETER => Ok(None),
            ERROR_ACCESS_DENIED if denied_is_gone => Ok(None),
            code => Err(format!("Cannot inspect process {pid}: Win32 error {code}").into()),
        };
    }
    let handle = Handle(raw);
    let mut exit = 0;
    let mut created = unsafe { mem::zeroed() };
    let mut exited = unsafe { mem::zeroed() };
    let mut kernel = unsafe { mem::zeroed() };
    let mut user = unsafe { mem::zeroed() };
    if unsafe { GetExitCodeProcess(handle.0, &mut exit) } == 0
        || unsafe { GetProcessTimes(handle.0, &mut created, &mut exited, &mut kernel, &mut user) }
            == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok((exit == 259).then_some(ProcessKey {
        pid,
        created: ((created.dwHighDateTime as u64) << 32) | created.dwLowDateTime as u64,
    }))
}

pub fn alive(key: &ProcessKey) -> Result<bool> {
    // Saved keys came from processes this user could open, so an inaccessible
    // process at the same PID (for example after a reboot) is a different process.
    Ok(query(key.pid, true)?.as_ref() == Some(key))
}

pub fn ancestry() -> Result<Vec<(u32, String)>> {
    ancestry_from(std::process::id())
}

pub fn ancestry_from(pid: u32) -> Result<Vec<(u32, String)>> {
    let raw = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if raw == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().into());
    }
    let snapshot = Handle(raw);
    let mut item: PROCESSENTRY32W = unsafe { mem::zeroed() };
    item.dwSize = mem::size_of::<PROCESSENTRY32W>() as u32;
    let mut map = HashMap::new();
    let mut ok = unsafe { Process32FirstW(snapshot.0, &mut item) };
    while ok != 0 {
        let length = item
            .szExeFile
            .iter()
            .position(|c| *c == 0)
            .unwrap_or(item.szExeFile.len());
        map.insert(
            item.th32ProcessID,
            (
                item.th32ParentProcessID,
                String::from_utf16_lossy(&item.szExeFile[..length]),
            ),
        );
        ok = unsafe { Process32NextW(snapshot.0, &mut item) };
    }
    if unsafe { GetLastError() } != 18 {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut result = Vec::new();
    let mut next = pid;
    for _ in 0..64 {
        let Some((parent, name)) = map.get(&next) else {
            break;
        };
        result.push((next, name.to_lowercase()));
        if *parent == next || *parent == 0 {
            break;
        }
        next = *parent;
    }
    Ok(result)
}

#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum_length: u16,
    buffer: *const u16,
}

#[link(name = "ntdll")]
extern "system" {
    fn NtQueryInformationProcess(
        process: HANDLE,
        class: u32,
        buffer: *mut c_void,
        size: u32,
        returned: *mut u32,
    ) -> i32;
}

pub fn command_line(pid: u32) -> Result<String> {
    let raw = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if raw.is_null() {
        return Err(std::io::Error::last_os_error().into());
    }
    let handle = Handle(raw);
    let mut length = 0;
    unsafe {
        NtQueryInformationProcess(handle.0, 60, std::ptr::null_mut(), 0, &mut length);
    }
    if !(mem::size_of::<UnicodeString>() as u32..=131_072).contains(&length) {
        return Err("Process command line size could not be determined".into());
    }
    let mut buffer = vec![0u64; (length as usize).div_ceil(8)];
    let status = unsafe {
        NtQueryInformationProcess(
            handle.0,
            60,
            buffer.as_mut_ptr().cast(),
            length,
            &mut length,
        )
    };
    if status < 0 {
        return Err(format!("Process command line query failed: NTSTATUS {status:#x}").into());
    }
    // The returned UNICODE_STRING points into this allocation; validate before dereferencing.
    let header = unsafe { &*buffer.as_ptr().cast::<UnicodeString>() };
    let start = header.buffer as usize;
    let low = buffer.as_ptr() as usize;
    let high = low + buffer.len() * 8;
    if !header.length.is_multiple_of(2)
        || !start.is_multiple_of(2)
        || start < low
        || start
            .checked_add(header.length as usize)
            .is_none_or(|v| v > high)
    {
        return Err("Invalid process command line buffer".into());
    }
    let value = unsafe { std::slice::from_raw_parts(header.buffer, header.length as usize / 2) };
    String::from_utf16(value).map_err(|e| Box::new(e) as Error)
}

pub fn arguments(command: &str) -> Result<Vec<String>> {
    use windows_sys::Win32::{Foundation::LocalFree, UI::Shell::CommandLineToArgvW};
    let wide: Vec<u16> = command.encode_utf16().chain(Some(0)).collect();
    let mut count = 0;
    let ptr = unsafe { CommandLineToArgvW(wide.as_ptr(), &mut count) };
    if ptr.is_null() {
        return Err(std::io::Error::last_os_error().into());
    }
    let result = (0..count)
        .map(|i| {
            let arg = unsafe { *ptr.add(i as usize) };
            let mut size = 0;
            unsafe {
                while *arg.add(size) != 0 {
                    size += 1;
                }
                String::from_utf16_lossy(std::slice::from_raw_parts(arg, size))
            }
        })
        .collect();
    unsafe { LocalFree(ptr.cast()) };
    Ok(result)
}

pub fn replace(from: &Path, to: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    let from: Vec<u16> = from.as_os_str().encode_wide().chain(Some(0)).collect();
    let to: Vec<u16> = to.as_os_str().encode_wide().chain(Some(0)).collect();
    if unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}
