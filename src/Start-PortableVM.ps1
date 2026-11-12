<#
  Starts the VM straight from this USB stick, using the hypervisor installed
  on this PC: VMware Workstation if present, otherwise VirtualBox. No VM list is shown.
  Double-click "Start VM.cmd" (one folder up) to run it.

  The VM boots this stick itself (raw disk). Before every start the launcher:
    - asks for administrator rights (needed to give a VM a physical disk),
    - checks the settings and names every setting that is wrong,
    - finds which disk number the stick has on this PC and checks that it really is
      this stick (MBR signature, size, partition layout) - otherwise nothing starts,
    - points the VM's raw-disk file at that disk number,
    - fixes the stick's drive letter in the VirtualBox files,
    - refuses to start the VM in one program while it has a saved state in the other.

  The checks and start steps are in PortableVM.psm1 next to this script.
  Settings: ..\LauncherData\settings.psd1. Log: ..\LauncherData\logs\launcher.log.
  -DryRun runs every check and logs what would change, without changing or starting anything.
#>
# Show-Message and Show-Question load System.Windows.Forms with Add-Type before they use the
# types, which the analyzer's compatibility profile cannot see: it lists only the assemblies that
# load by default.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'Show-Message and Show-Question load System.Windows.Forms with Add-Type first.')]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

# Show $Message in a dialog titled $Caption, 'Portable VM' when empty, with the icon $Icon (Error,
# Warning or Information) on the default desktop, so it shows although the console is hidden. A
# dry run shows nothing.
function Show-Message([string]$Message, [string]$Icon, [string]$Caption) {
    if ($DryRun) { return }
    if (-not $Caption) { $Caption = 'Portable VM' }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]$Icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1, [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

# --- Administrator rights -------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) {
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Minimized `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    } catch {
        Show-Message 'The launcher needs administrator rights, because the VM boots this USB stick directly.' 'Warning'
    }
    exit
}

# --- Start -------------------------------------------------------------------------------
# PortableVM.psm1 next to this script checks the settings and the stick and starts the VM. It logs
# to LauncherData\logs\launcher.log beside the Launcher folder and returns the exit code, the
# message to show and the dialog's title. A module that cannot be loaded, or a dialog that fails,
# is logged as an unexpected error, as any error was before. As before, a message shows only once
# its STOPPED line is in the log; without LauncherData there is no log, and it shows unlogged.

# Ask $Message as a question in a dialog titled $Caption, 'Portable VM' when empty, on the default
# desktop, with Yes and No and No as the default button, and return whether the answer is Yes.
function Show-Question([string]$Message, [string]$Caption) {
    if (-not $Caption) { $Caption = 'Portable VM' }
    Add-Type -AssemblyName System.Windows.Forms
    $answer = [System.Windows.Forms.MessageBox]::Show($Message, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2, [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
    $answer -eq [System.Windows.Forms.DialogResult]::Yes
}

# Append "STOPPED: $Message" in the log's format to LauncherData\logs\launcher.log beside the
# Launcher folder, creating the logs folder when it is missing, and return whether the message may
# show: when the line is in the log, or when there is no LauncherData and so no log to write.
function Add-StopLine([string]$Message) {
    $data = Join-Path (Split-Path $Here) 'LauncherData'
    if (-not (Test-Path -LiteralPath $data -PathType Container)) { return $true }
    try {
        $logs = Join-Path $data 'logs'
        $null = New-Item -ItemType Directory -Path $logs -Force
        Add-Content -LiteralPath (Join-Path $logs 'launcher.log') -Value ('{0:yyyy-MM-dd HH:mm:ss}  STOPPED: {1}' -f (Get-Date), $Message)
        $true
    } catch {
        Write-Host "launcher.log could not be written: $($_.Exception.Message)"
        $false
    }
}

# The tests set PVM_TEST so that the module's adapters refuse to run; a value left in this
# process's environment must not stop a real start.
Remove-Item -LiteralPath 'Env:\PVM_TEST' -ErrorAction SilentlyContinue
try {
    Import-Module -Name (Join-Path $Here 'PortableVM.psm1') -Force
    $result = Invoke-PortableVM -LauncherPath $Here -DryRun:$DryRun -AskResume { param([string]$Question, [string]$Caption) Show-Question -Message $Question -Caption $Caption }
} catch {
    $result = [pscustomobject]@{ ExitCode = 1; Message = "Unexpected error: $($_.Exception.Message)"; Icon = 'Error'; Caption = 'Portable VM' }
    if (-not (Add-StopLine -Message $result.Message)) { $result.Message = '' }
}
try {
    if ($result.Message) { Show-Message -Message $result.Message -Icon $result.Icon -Caption $result.Caption }
} catch {
    $null = Add-StopLine -Message "Unexpected error: $($_.Exception.Message)"
    $result.ExitCode = 1
}
exit $result.ExitCode
