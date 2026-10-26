using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ServerMaster.Windows.Services;

// Only app-owned servers belong here. Installers and user-launched applications must not join this job.
public static class OwnedProcesses
{
    private static readonly Lazy<SafeFileHandle> Job = new(CreateJob);

    public static void Track(Process process)
    {
        Assign(Job.Value, process);
    }

    public static IDisposable CreateGroup(Process process)
    {
        var job = CreateJob();
        try
        {
            Assign(job, process);
            return job;
        }
        catch
        {
            job.Dispose();
            throw;
        }
    }

    private static void Assign(SafeFileHandle job, Process process)
    {
        if (AssignProcessToJobObject(job, process.Handle)) return;
        var error = Marshal.GetLastWin32Error();
        if (process.HasExited) return;
        try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        throw new Win32Exception(error, "Could not attach the server to application lifetime management.");
    }

    private static SafeFileHandle CreateJob()
    {
        var handle = CreateJobObject(IntPtr.Zero, null);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } };
        if (SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>())) return handle;
        var error = Marshal.GetLastWin32Error();
        handle.Dispose();
        throw new Win32Exception(error);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass, ref ExtendedLimits limits, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
}
