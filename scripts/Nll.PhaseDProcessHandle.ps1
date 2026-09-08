# OS process metadata/wait/termination only. No process memory access, injection or client changes.
function Open-PhaseDProcess {
    param([int]$Id, [switch]$ForTermination)
    if (-not ('Nll.PhaseD.ProcessHandle' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Nll.PhaseD {
    public sealed class ProcessHandle : IDisposable {
        private readonly SafeWaitHandle handle;
        private readonly bool canTerminate;
        private ProcessHandle(SafeWaitHandle handle, bool canTerminate) {
            this.handle = handle; this.canTerminate = canTerminate;
        }
        public static ProcessHandle Open(int id, bool forTermination) {
            // SYNCHRONIZE | QUERY_LIMITED_INFORMATION; TERMINATE only for an explicit stop.
            SafeWaitHandle handle = OpenProcess(0x00101000u | (forTermination ? 1u : 0u), false, id);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error(); handle.Dispose();
                if (error == 87) return null; // no such process
                throw new Win32Exception(error);
            }
            return new ProcessHandle(handle, forTermination);
        }
        public DateTime StartTime {
            get {
                long creation, exit, kernel, user;
                if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return DateTime.FromFileTimeUtc(creation);
            }
        }
        public string Path {
            get {
                int length = 32768;
                StringBuilder buffer = new StringBuilder(length);
                if (!QueryFullProcessImageName(handle, 0, buffer, ref length))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return buffer.ToString();
            }
        }
        public bool HasExited { get { return WaitForExit(0); } }
        public bool WaitForExit(int milliseconds) {
            if (milliseconds < -1) throw new ArgumentOutOfRangeException("milliseconds");
            uint result = WaitForSingleObject(handle, milliseconds == -1 ? uint.MaxValue : (uint)milliseconds);
            if (result == 0) return true;
            if (result == 258) return false;
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        public void WaitForExit() { WaitForExit(-1); }
        public void Kill() {
            if (!canTerminate) throw new InvalidOperationException("phase_d_process_stop_not_authorized");
            if (!TerminateProcess(handle, 1)) {
                int error = Marshal.GetLastWin32Error();
                if (!HasExited) throw new Win32Exception(error);
            }
        }
        public void Dispose() { handle.Dispose(); }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeWaitHandle OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(SafeWaitHandle handle, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(SafeWaitHandle handle, int flags, StringBuilder path, ref int length);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(SafeWaitHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(SafeWaitHandle handle, uint exitCode);
    }
}
'@
    }
    [Nll.PhaseD.ProcessHandle]::Open($Id, [bool]$ForTermination)
}
