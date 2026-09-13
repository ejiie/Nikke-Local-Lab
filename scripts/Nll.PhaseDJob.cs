// Windows process lifecycle only. No process memory access or client modification.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Nll.PhaseD
{
  public sealed class ExecutionJob : IDisposable
  {
    private readonly SafeFileHandle handle;
    private bool launched;
    private ExecutionJob(SafeFileHandle value) { handle = value; }
    private static void Check(bool value) { if (!value) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public static ExecutionJob Create(string name)
    {
      SafeFileHandle value = CreateJobObject(IntPtr.Zero, name);
      int error = Marshal.GetLastWin32Error();
      if (value.IsInvalid || error == 183) { value.Dispose(); throw new Win32Exception(error); }
      ExecutionJob job = new ExecutionJob(value);
      try
      {
        Extended limits = new Extended(); limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE, no breakaway.
        Check(SetInformationJobObject(value, 9, ref limits, (uint)Marshal.SizeOf(typeof(Extended))));
        job.Validate(); return job;
      }
      catch { job.Dispose(); throw; }
    }
    public static ExecutionJob Open(string name)
    {
      // No ASSIGN_PROCESS permission in watcher/recovery; never recreate an absent job.
      SafeFileHandle value = OpenJobObject(0x0004u | 0x0008u, false, name);
      if (value.IsInvalid) { int error = Marshal.GetLastWin32Error(); value.Dispose(); throw new Win32Exception(error); }
      ExecutionJob job = new ExecutionJob(value);
      try { job.Validate(); return job; } catch { job.Dispose(); throw; }
    }
    public void Validate()
    {
      Extended limits;
      Check(QueryLimits(handle, 9, out limits, (uint)Marshal.SizeOf(typeof(Extended)), IntPtr.Zero));
      if (limits.Basic.Flags != 0x2000) throw new InvalidOperationException("phase_d_job_limits_invalid");
    }
    public bool Contains(int id)
    {
      using (Process process = Process.GetProcessById(id))
      {
        bool result; Check(IsProcessInJob(process.Handle, handle, out result)); return result;
      }
    }
    public Process Start(string executable, string arguments)
    {
      if (launched) throw new InvalidOperationException("phase_d_job_start_repeated");
      launched = true;
      IntPtr size = IntPtr.Zero, list = IntPtr.Zero, jobs = IntPtr.Zero;
      bool initialized = false;
      ProcessInfo created = new ProcessInfo();
      try
      {
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        list = Marshal.AllocHGlobal(size);
        Check(InitializeProcThreadAttributeList(list, 1, 0, ref size));
        initialized = true;
        jobs = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(jobs, handle.DangerousGetHandle());
        Check(UpdateProcThreadAttribute(list, 0, new IntPtr(0x0002000D), jobs, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero));
        StartupEx startup = new StartupEx();
        startup.Startup.Size = Marshal.SizeOf(typeof(StartupEx)); startup.Attributes = list;
        // Assignment is part of creation, not a later AssignProcessToJobObject call.
        // Suspended only to retain exact process identity before any user code runs.
        Check(CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
            IntPtr.Zero, IntPtr.Zero, false, 0x00080000u | 0x00000004u | 0x08000000u,
            IntPtr.Zero, IntPtr.Zero, ref startup, out created));
        Process process = Process.GetProcessById(created.ProcessId);
        try
        {
          bool member; Check(IsProcessInJob(created.Process, handle, out member));
          if (!member) throw new InvalidOperationException("phase_d_job_assignment_unproven");
          IntPtr retained = process.Handle;
          if (ResumeThread(created.Thread) != 1) throw new InvalidOperationException("phase_d_job_resume_unproven");
          return process;
        }
        catch { process.Dispose(); throw; }
      }
      finally
      {
        if (created.Thread != IntPtr.Zero) CloseHandle(created.Thread);
        if (created.Process != IntPtr.Zero) CloseHandle(created.Process);
        if (list != IntPtr.Zero) { if (initialized) DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); }
        if (jobs != IntPtr.Zero) Marshal.FreeHGlobal(jobs);
        GC.KeepAlive(handle);
      }
    }
    public uint ActiveProcesses
    {
      get { Accounting info; Check(QueryAccounting(handle, 1, out info, (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero)); return info.ActiveProcesses; }
    }
    public void TerminateAndWait(int milliseconds)
    {
      Validate(); Check(TerminateJobObject(handle, 1));
      Stopwatch deadline = Stopwatch.StartNew();
      do { if (ActiveProcesses == 0) return; System.Threading.Thread.Sleep(25); } while (deadline.ElapsedMilliseconds < milliseconds);
      throw new InvalidOperationException("phase_d_job_zero_unproven");
    }
    public void Dispose() { handle.Dispose(); }
    [StructLayout(LayoutKind.Sequential)]
    private struct Basic
    {
      public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinWorking, MaxWorking;
      public uint ActiveLimit; public UIntPtr Affinity; public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Io { public ulong A, B, C, D, E, F; }
    [StructLayout(LayoutKind.Sequential)] private struct Extended { public Basic Basic; public Io Io; public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob; }
    [StructLayout(LayoutKind.Sequential)] private struct Accounting { public long A, B, C, D; public uint PageFaults, TotalProcesses, ActiveProcesses, TotalTerminated; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Startup
    {
      public int Size; public string Reserved, Desktop, Title; public uint X, Y, XSize, YSize, XCount, YCount, Fill, Flags;
      public short Show, ReservedSize; public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupEx { public Startup Startup; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObject(IntPtr security, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref Extended info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true)] private static extern bool QueryLimits(SafeFileHandle job, int kind, out Extended info, uint size, IntPtr returned);
    [DllImport("kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true)] private static extern bool QueryAccounting(SafeFileHandle job, int kind, out Accounting info, uint size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool IsProcessInJob(IntPtr process, SafeFileHandle job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(SafeFileHandle job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    // A null native current-directory pointer inherits the parent's directory.
    // IntPtr.Zero also keeps this shared source compatible with the C# 5 compiler
    // in Windows PowerShell 5.1 without nullable syntax or suppressed diagnostics.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcess(string app, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, IntPtr directory, ref StartupEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
  }
}
