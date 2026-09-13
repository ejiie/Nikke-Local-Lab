// Query-only OS process metadata. No VM_READ, target memory, injection or hooks.
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Nll.Fx {
    public sealed class ProcessIdentityQueryException : Win32Exception {
        public string Operation { get; private set; }
        public int ProcessId { get; private set; }
        public ProcessIdentityQueryException(string operation, int processId, int error)
            : base(error) { Operation = operation; ProcessId = processId; }
    }
    public sealed class ProcessIdentity {
        public string ImagePath { get; private set; }
        public long CreatedFileTime { get; private set; }
        public bool JobMember { get; private set; }
        public static ProcessIdentity Read(int id) {
            return Read(id, null);
        }
        public static ProcessIdentity Read(int id, string jobName) {
            if (id <= 0) throw new ArgumentOutOfRangeException("id");
            // SYNCHRONIZE permits a signalled-handle check without VM_READ.
            using (SafeFileHandle process = OpenProcess(0x101000, false, id)) {
                if (process.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 87) return null; // the snapshot PID no longer exists
                    throw new ProcessIdentityQueryException("OpenProcess", id, error);
                }
                if (Exited(process, id)) return null;
                StringBuilder image = new StringBuilder(32768); uint size = 32768;
                long created, exited, kernel, user;
                if (!QueryFullProcessImageName(process, 0, image, ref size)) {
                    int error = Marshal.GetLastWin32Error();
                    if (Exited(process, id)) return null;
                    throw new ProcessIdentityQueryException("QueryFullProcessImageName", id, error);
                }
                if (!GetProcessTimes(process, out created, out exited, out kernel, out user)) {
                    int error = Marshal.GetLastWin32Error();
                    if (Exited(process, id)) return null;
                    throw new ProcessIdentityQueryException("GetProcessTimes", id, error);
                }
                if (exited != 0 || Exited(process, id)) return null;
                bool member = false;
                if (!string.IsNullOrEmpty(jobName)) {
                    using (SafeFileHandle job = OpenJobObject(4, false, jobName)) {
                        if (job.IsInvalid)
                            throw new ProcessIdentityQueryException("OpenJobObject", id, Marshal.GetLastWin32Error());
                        if (!IsProcessInJob(process, job, out member))
                            throw new ProcessIdentityQueryException("IsProcessInJob", id, Marshal.GetLastWin32Error());
                    }
                }
                return new ProcessIdentity { ImagePath = image.ToString(), CreatedFileTime = created, JobMember = member };
            }
        }
        private static bool Exited(SafeFileHandle process, int id) {
            uint result = WaitForSingleObject(process, 0);
            if (result == 0) return true;
            if (result == 258) return false;
            throw new ProcessIdentityQueryException("WaitForSingleObject", id, Marshal.GetLastWin32Error());
        }
        [DllImport("kernel32.dll", SetLastError=true)] private static extern uint WaitForSingleObject(SafeFileHandle process, uint milliseconds);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern SafeFileHandle OpenJobObject(uint access, bool inherit, string name);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool IsProcessInJob(SafeFileHandle process, SafeFileHandle job, out bool member);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern SafeFileHandle OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool QueryFullProcessImageName(SafeFileHandle process, uint flags, StringBuilder path, ref uint size);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetProcessTimes(SafeFileHandle process, out long created, out long exited, out long kernel, out long user);
    }
}
