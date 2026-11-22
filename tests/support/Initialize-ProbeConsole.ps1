$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ProbeConsoleHandles {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetStdHandle(int id, IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    public static void Initialize() {
        var input = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        var output = CreateFileW("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (input == (IntPtr)(-1) || output == (IntPtr)(-1)) throw new Win32Exception();
        if (!SetHandleInformation(input, 1, 1) || !SetHandleInformation(output, 1, 1))
            throw new Win32Exception();
        if (!SetStdHandle(-10, input) || !SetStdHandle(-11, output) || !SetStdHandle(-12, output))
            throw new Win32Exception();
    }
}
'@
[ProbeConsoleHandles]::Initialize()
