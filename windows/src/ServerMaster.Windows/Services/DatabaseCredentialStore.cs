using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ServerMaster.Windows.Services;

public static class DatabaseCredentialStore
{
    private const int Generic = 1;
    private const int LocalMachine = 2;
    private static string Target(string database) => "ServerMaster/Database/" + database;

    public static void Save(string database, string user, string password)
    {
        var bytes = Encoding.Unicode.GetBytes(password);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = Generic, TargetName = Target(database), UserName = user,
                CredentialBlobSize = bytes.Length, CredentialBlob = blob, Persist = LocalMachine
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not save database credentials in Windows Credential Manager.");
        }
        finally
        {
            Array.Clear(bytes);
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            Marshal.FreeHGlobal(blob);
        }
    }

    public static (string User, string Password)? Read(string database)
    {
        if (!CredRead(Target(database), Generic, 0, out var address))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == 1168) return null;
            throw new Win32Exception(error, "Could not read database credentials from Windows Credential Manager.");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(address);
            var password = credential.CredentialBlobSize == 0 ? "" :
                Marshal.PtrToStringUni(credential.CredentialBlob, credential.CredentialBlobSize / 2) ?? "";
            return (credential.UserName ?? "", password);
        }
        finally { CredFree(address); }
    }

    public static void Delete(string database)
    {
        if (!CredDelete(Target(database), Generic, 0) && Marshal.GetLastWin32Error() != 1168)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not remove stored database credentials.");
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr credential);
}
