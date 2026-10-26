using System.Security.Principal;

namespace ServerMaster.Windows.Services;

public static class WindowsElevation
{
    public static bool IsElevated => new WindowsPrincipal(WindowsIdentity.GetCurrent())
        .IsInRole(WindowsBuiltInRole.Administrator);
}
