// Bounded synthetic feasibility probe ONLY. Not an admission or cached-hash API.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Nll.ValidationProbe
{
    public static class ChangeTracking
    {
        public static string Stage { get; private set; }
        public static string ReadJournal(FileStream file)
        {
            Stage = "physical_identity";
            FileInformation info;
            if (!GetFileInformationByHandle(file.SafeFileHandle, out info)) Fail();
            if (info.Links != 1 || (info.Attributes & 0x400) != 0) throw new InvalidOperationException("generation_physical_identity_invalid");
            var volumePath = @"\\.\" + Path.GetPathRoot(file.Name).TrimEnd('\\');
            using (var volume = CreateFile(volumePath, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
            {
                Stage = "volume_open";
                if (volume.IsInvalid) Fail();
                var journal = new byte[128]; uint count;
                Stage = "journal_query";
                if (!DeviceIoControl(volume, 0x900f4, null, 0, journal, journal.Length, out count, IntPtr.Zero)) Fail();
                if (count < 56) throw new InvalidOperationException("generation_journal_shape_invalid");
                var record = new byte[4096]; var versions = new byte[] { 2, 0, 2, 0 };
                Stage = "file_usn_query";
                if (!DeviceIoControl(file.SafeFileHandle, 0x900eb, versions, versions.Length, record, record.Length, out count, IntPtr.Zero)) Fail();
                if (count < 60 || BitConverter.ToUInt16(record, 4) != 2) throw new InvalidOperationException("generation_file_usn_unsupported");
                return string.Join(":", new object[] {
                    info.Volume, info.IndexHigh, info.IndexLow, BitConverter.ToUInt64(journal, 0),
                    BitConverter.ToInt64(journal, 8), BitConverter.ToInt64(journal, 16),
                    BitConverter.ToInt64(journal, 24), BitConverter.ToInt64(record, 24) });
            }
        }
        private static void Fail() { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle file, uint code, byte[] input, int inputSize, byte[] output, int outputSize, out uint returned, IntPtr overlapped);
    }
}
