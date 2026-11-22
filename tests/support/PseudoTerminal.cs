using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace CopilotTerminalRestore.Tests
{
    public sealed class PseudoTerminal : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        struct Coord { public short X; public short Y; }
        [StructLayout(LayoutKind.Sequential)]
        struct StartupInfo
        {
            public int cb;
            public IntPtr reserved, desktop, title;
            public int x, y, xSize, ySize, xChars, yChars, fill, flags;
            public short show, reservedSize;
            public IntPtr reservedBytes, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct StartupInfoEx { public StartupInfo info; public IntPtr attributes; }
        [StructLayout(LayoutKind.Sequential)]
        struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreatePipe(out IntPtr read, out IntPtr write, IntPtr security, int size);
        [DllImport("kernel32.dll")]
        static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, int flags, out IntPtr console);
        [DllImport("kernel32.dll")]
        static extern void ClosePseudoConsole(IntPtr console);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")]
        static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupInfoEx startup, out ProcessInfo process);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        readonly object gate = new object();
        readonly StringBuilder output = new StringBuilder();
        FileStream input;
        FileStream reader;
        Task readerTask;
        Process process;
        IntPtr console;
        public int ProcessId { get { return process.Id; } }
        public bool HasExited { get { return process.HasExited; } }
        public string Output { get { lock (gate) { return output.ToString(); } } }

        public PseudoTerminal(string command, string cwd)
        {
            IntPtr inputRead = IntPtr.Zero, inputWrite = IntPtr.Zero;
            IntPtr outputRead = IntPtr.Zero, outputWrite = IntPtr.Zero, attributes = IntPtr.Zero;
            try
            {
                if (!CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0) ||
                    !CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0))
                    throw new Win32Exception();
                int hr = CreatePseudoConsole(new Coord { X = 120, Y = 40 }, inputRead, outputWrite, 0, out console);
                if (hr != 0) Marshal.ThrowExceptionForHR(hr);
                IntPtr bytes = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
                attributes = Marshal.AllocHGlobal(bytes);
                if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref bytes)) throw new Win32Exception();
                if (!UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x20016, console, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                    throw new Win32Exception();
                var startup = new StartupInfoEx();
                startup.info.cb = Marshal.SizeOf<StartupInfoEx>();
                startup.attributes = attributes;
                ProcessInfo pi;
                if (!CreateProcessW(null, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                    0x00080000, IntPtr.Zero, cwd, ref startup, out pi)) throw new Win32Exception();
                try { process = Process.GetProcessById(pi.pid); }
                finally { CloseHandle(pi.process); CloseHandle(pi.thread); }
                input = new FileStream(new SafeFileHandle(inputWrite, true), FileAccess.Write);
                inputWrite = IntPtr.Zero;
                reader = new FileStream(new SafeFileHandle(outputRead, true), FileAccess.Read);
                outputRead = IntPtr.Zero;
                readerTask = Task.Run(() =>
                {
                    var buffer = new byte[8192];
                    var decoder = Encoding.UTF8.GetDecoder();
                    var chars = new char[8192];
                    try
                    {
                        int count;
                        while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            int length = decoder.GetChars(buffer, 0, count, chars, 0);
                            var text = new string(chars, 0, length);
                            lock (gate) { output.Append(text); }
                            if (text.Contains("\x1b[6n")) Send("\x1b[1;1R");
                        }
                    }
                    catch (IOException) { }
                    catch (ObjectDisposedException) { }
                });
            }
            catch { Dispose(); throw; }
            finally
            {
                if (attributes != IntPtr.Zero) { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
                if (inputRead != IntPtr.Zero) CloseHandle(inputRead);
                if (inputWrite != IntPtr.Zero) CloseHandle(inputWrite);
                if (outputRead != IntPtr.Zero) CloseHandle(outputRead);
                if (outputWrite != IntPtr.Zero) CloseHandle(outputWrite);
            }
        }

        public void Send(string text)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            lock (input) { input.Write(bytes, 0, bytes.Length); input.Flush(); }
        }

        public void CloseConsole()
        {
            var handle = Interlocked.Exchange(ref console, IntPtr.Zero);
            if (handle != IntPtr.Zero) ClosePseudoConsole(handle);
        }

        public void Dispose()
        {
            CloseConsole();
            if (process != null && !process.HasExited && !process.WaitForExit(5000))
                throw new InvalidOperationException("Probe process did not exit after console closure: " + process.Id);
            if (input != null) input.Dispose();
            if (reader != null) reader.Dispose();
            if (readerTask != null) readerTask.Wait(5000);
            if (process != null) process.Dispose();
        }
    }
}
