# The CI stage test of the repository standard, which run-stage runs on Windows under Windows
# PowerShell 5.1 from the top of the repository: every Pester test through tests\run-checks.ps1,
# in Windows PowerShell 5.1, the launcher's own engine, then in PowerShell 7 on the same runner.
# A failed or skipped test fails the stage (-FailOnSkip). install-tools has put the pinned Pester
# on the module path, which PowerShell 7 reads too. Exits with the first failing run's code.
# Under run-stage on a Windows runner, whose account is an administrator, Git Bash turns on the
# backup and restore privileges for this script, and with them a Deny rule no longer stops a read.
# Some tests set such a rule to make a folder or file unreadable, as it is for the launcher's
# user, so this script turns both privileges off in its own token first; the test runs it starts
# inherit that.
# Continue, so a line the checks write to stderr does not stop this script; each exit code decides.
$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class PvmCiPrivilege {
    [StructLayout(LayoutKind.Sequential)]
    private struct Luid { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TokenPrivileges { public uint Count; public Luid Luid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValue(string system, string name, out Luid luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returnLength);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    // Turn the privilege off in this process's token; one the token does not hold stays off.
    public static void Disable(string name) {
        IntPtr token;
        // TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) { throw new Win32Exception(); }
        try {
            Luid luid;
            if (!LookupPrivilegeValue(null, name, out luid)) { throw new Win32Exception(); }
            TokenPrivileges state = new TokenPrivileges();
            state.Count = 1;
            state.Luid = luid;
            state.Attributes = 0;
            if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) { throw new Win32Exception(); }
        } finally {
            CloseHandle(token);
        }
    }
}
'@
foreach ($privilege in 'SeBackupPrivilege', 'SeRestorePrivilege') { [PvmCiPrivilege]::Disable($privilege) }
# The token's state, for the log: both lines must say Disabled, or show no such privilege. Windows'
# own whoami, since Git Bash puts its own first on the Path.
& (Join-Path $env:SystemRoot 'System32\whoami.exe') /priv | Select-String -Pattern 'SeBackupPrivilege|SeRestorePrivilege' | ForEach-Object { $_.Line }

$checks = Join-Path $PSScriptRoot '..\tests\run-checks.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File $checks -SkipAnalyzer -FailOnSkip
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
pwsh -NoProfile -ExecutionPolicy Bypass -File $checks -SkipAnalyzer -FailOnSkip
exit $LASTEXITCODE
