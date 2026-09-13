using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

// OS metadata for this bootstrap and the child it just created. Query-only;
// no logon, impersonation, token assignment, target memory or binary changes.
internal static class ExecutionTokenObservation
{
    // Synchronous by design: do not introduce an await/thread transition between
    // the pre-start observation, Process.Start and the post-start observation.
    internal static void WriteNew(string path, object value)
    {
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        JsonSerializer.Serialize(output, value, new JsonSerializerOptions { WriteIndented = true });
        output.Flush(flushToDisk: true);
    }
    internal sealed record Token(int ElevationType, int Elevated, int IntegrityRid,
        int Type, int SessionId, int? ImpersonationLevel);
    internal sealed record Query(string Status, Token? Token, string? Operation, int? Error);
    internal sealed record ProcessState(int ProcessId, long CreatedFileTime, Query Token);
    internal sealed record CurrentState(ProcessState Process, uint ThreadId, Query Thread,
        bool CompatLayerPresent, bool CompatRunAsAdmin, bool CompatRunAsInvoker);
    internal static CurrentState Current()
    {
        using var process = Process.GetCurrentProcess();
        var layer = Environment.GetEnvironmentVariable("__COMPAT_LAYER");
        var parts = (layer ?? string.Empty).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return new(Child(process), GetCurrentThreadId(), ThreadToken(), layer is not null,
            parts.Contains("RunAsAdmin", StringComparer.OrdinalIgnoreCase),
            parts.Contains("RunAsInvoker", StringComparer.OrdinalIgnoreCase));
    }
    internal static ProcessState Child(Process process) => new(process.Id,
        process.StartTime.ToUniversalTime().ToFileTimeUtc(), ProcessToken(process.SafeHandle));
    private static Query ProcessToken(SafeProcessHandle process)
    {
        if (!OpenProcessToken(process, 8, out var token))
            return new("query_failed", null, "OpenProcessToken", Marshal.GetLastWin32Error());
        using (token) return Describe(token);
    }
    private static Query ThreadToken()
    {
        if (!OpenThreadToken(new IntPtr(-2), 8, true, out var token))
        {
            var error = Marshal.GetLastWin32Error();
            return new(error == 1008 ? "no_thread_token" : "query_failed", null, "OpenThreadToken", error);
        }
        using (token) return Describe(token);
    }
    private static Query Describe(SafeFileHandle token)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        try
        {
            var integrity = Info(token, 25);
            int rid;
            try
            {
                var sid = new SecurityIdentifier(Marshal.ReadIntPtr(integrity)).Value;
                if (!sid.StartsWith("S-1-16-", StringComparison.Ordinal) ||
                    !int.TryParse(sid.AsSpan(7), out rid)) return new("query_failed", null, "IntegritySid", null);
            }
            finally { Marshal.FreeHGlobal(integrity); }
            var type = Number(token, 8);
            return new("observed", new(Number(token, 18), Number(token, 20), rid, type,
                Number(token, 12), type == 2 ? Number(token, 9) : null), null, null);
        }
        catch (Win32Exception error) { return new("query_failed", null, "GetTokenInformation", error.NativeErrorCode); }
    }
    private static int Number(SafeFileHandle token, int kind)
    {
        var data = Info(token, kind);
        try { return Marshal.ReadInt32(data); } finally { Marshal.FreeHGlobal(data); }
    }
    private static IntPtr Info(SafeFileHandle token, int kind)
    {
        GetTokenInformation(token, kind, IntPtr.Zero, 0, out var size);
        if (size is < 4 or > 65536) throw new Win32Exception(Marshal.GetLastWin32Error());
        var data = Marshal.AllocHGlobal(size);
        if (GetTokenInformation(token, kind, data, size, out _)) return data;
        var error = Marshal.GetLastWin32Error(); Marshal.FreeHGlobal(data); throw new Win32Exception(error);
    }
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeFileHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenThreadToken(IntPtr thread, uint access, bool openAsSelf, out SafeFileHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(SafeFileHandle token, int kind, IntPtr data, int size, out int returned);
}
