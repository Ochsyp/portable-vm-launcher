# -------------------------------------------------------
#                  DEPLOY PORTABLE VM
# -------------------------------------------------------
#
# Copies the launcher from this clone to a stick. -Target is the folder on the stick's Data
# partition that holds the Launcher folder, for example X:\. Run it in Windows PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Deploy-PortableVM.ps1 -Target X:\
# It refuses, changing nothing, while a VM runs on this PC, when Launcher or its settings.psd1
# is missing, when Launcher.new, "Start VM.cmd.new" or Launcher.previous is left from an earlier
# deploy, or when a .cmd at -Target is in the way. Otherwise it builds Launcher.new from src\,
# the stick's settings.psd1 and launcher.log, a VERSION from git describe and a SHA256SUMS of
# the code, and checks every copy against the clone. Then Launcher becomes Launcher.previous,
# Launcher.new becomes Launcher, the old launcher .cmd files at -Target move into
# Launcher.previous and "Start VM.cmd" takes their place. It deletes nothing, never touches the
# VM folders and names no file from the stick in its output; when a step fails it says what is
# left to fix by hand. -WhatIf runs the checks only. Exits 0 when done, 1 when it refused or
# failed.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Target
)

$ErrorActionPreference = 'Stop'

$CodeFiles = @('Start-PortableVM.ps1', 'PortableVM.psm1')
# The stick's own files in Launcher, which the launcher still reads there.
$KeptFiles = @('settings.psd1', 'launcher.log')
$CmdName = 'Start VM.cmd'
# vmware-vmx% also covers the debug and stats builds of VMware's VM process.
$VmProcessFilter = "Name LIKE 'vmware-vmx%' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
# A .cmd that starts the launcher runs a .ps1 below %~dp0Launcher\, with or without a backslash
# after %~dp0.
$LauncherCmdPattern = '(?i)%~dp0\\?Launcher\\[^"\r\n]*\.ps1'

# Return the version of the clone at $RepositoryPath as git describe gives it: the nearest tag,
# else the commit, with -dirty for uncommitted changes; 'unknown' when git cannot tell.
function Get-DeployVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    $output = @()
    $exitCode = 1
    # git's stderr would stop the script under $ErrorActionPreference Stop.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $RepositoryPath describe --tags --always --dirty 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Verbose "git describe could not run: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -eq 0 -and $output.Count -eq 1 -and $output[0].Trim()) { return $output[0].Trim() }
    'unknown'
}

# Return the names of the VM processes, VMware's or VirtualBox's, that run on this PC.
function Get-DeployVmProcess {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Get-CimInstance -ClassName Win32_Process -Filter $VmProcessFilter | ForEach-Object { $_.Name }
}

# Return the SHA-256 hash of the file $Path in lowercase hex.
function Get-DeployHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Return the .cmd files directly in the folder $Folder that start the launcher, which their text
# shows by running a .ps1 below %~dp0Launcher\. Throws when one cannot be read.
function Find-DeployLauncherCmd {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param([Parameter(Mandatory)][string]$Folder)
    Get-ChildItem -LiteralPath $Folder -Filter '*.cmd' -File | Where-Object {
        $_.Extension -eq '.cmd' -and [IO.File]::ReadAllText($_.FullName) -match $LauncherCmdPattern
    }
}

# Copy the file $Source to $Destination and throw when the copy's SHA-256 differs from the
# source's. Returns the hash.
function Copy-DeployFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    Copy-Item -LiteralPath $Source -Destination $Destination
    $hash = Get-DeployHash -Path $Source
    if ((Get-DeployHash -Path $Destination) -ne $hash) { throw "The copy of $(Split-Path $Source -Leaf) does not match the clone." }
    $hash
}

# Rename $Path to $NewName in the same folder. A virus scanner often holds a fresh file for a
# moment, so a failed rename is tried twice more, half a second apart, before it throws.
function Rename-DeployItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NewName
    )
    for ($attempt = 1; ; $attempt++) {
        try {
            Rename-Item -LiteralPath $Path -NewName $NewName
            return
        } catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Deploy the launcher from the clone at $RepositoryPath to the stick folder $Target, as the header
# describes. Throws with the reason, before any change, when a check fails; a failure after the
# first change says what is left to fix by hand. Returns the Version deployed and MovedCmdCount,
# the number of old launcher .cmd files moved into Launcher.previous; returns nothing under
# -WhatIf.
function Invoke-PvmDeploy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Target
    )
    $launcher = Join-Path $Target 'Launcher'
    $staged = Join-Path $Target 'Launcher.new'
    $previous = Join-Path $Target 'Launcher.previous'
    $cmdTarget = Join-Path $Target $CmdName
    $cmdStaged = Join-Path $Target "$CmdName.new"
    $leftovers = "Launcher.new and '$CmdName.new'"
    $sources = @($CodeFiles | ForEach-Object { Join-Path (Join-Path $RepositoryPath 'src') $_ })
    $cmdSource = Join-Path $RepositoryPath $CmdName

    foreach ($source in $sources + $cmdSource) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "The clone has no $(Split-Path $source -Leaf)." }
    }
    if (-not (Test-Path -LiteralPath $launcher -PathType Container)) {
        if (Test-Path -LiteralPath $previous) {
            throw "The target has no Launcher folder, but Launcher.previous holds the launcher that an interrupted deploy replaced, with the stick's settings and log. Rename Launcher.previous back to Launcher, remove $leftovers if they are there, then deploy again."
        }
        throw 'The target has no Launcher folder. Create it, copy examples\settings.example.psd1 into it as settings.psd1 and fill that in first.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $launcher 'settings.psd1') -PathType Leaf)) {
        throw 'The target has no Launcher\settings.psd1. Copy examples\settings.example.psd1 there and fill it in first.'
    }
    $running = @(Get-DeployVmProcess)
    if ($running.Count -gt 0) { throw "A VM runs on this PC ($($running -join ', ')). Shut the guest down first." }
    foreach ($leftover in $staged, $cmdStaged) {
        if (Test-Path -LiteralPath $leftover) { throw "$(Split-Path $leftover -Leaf) is left from an earlier deploy and holds only copies. Remove it first." }
    }
    if (Test-Path -LiteralPath $previous) {
        throw 'Launcher.previous holds the launcher that the last deploy replaced. Remove it or move it away first.'
    }
    # The .cmd files are checked now, so that nothing they hold can stop the last step after the swap.
    try { $oldCmds = @(Find-DeployLauncherCmd -Folder $Target) }
    catch { throw "A .cmd file at the target cannot be read, so the old launcher .cmd cannot be found: $($_.Exception.Message)" }
    if ((Test-Path -LiteralPath $cmdTarget) -and @($oldCmds | Where-Object { $_.Name -eq $CmdName }).Count -eq 0) {
        throw "'$CmdName' at the target does not start the launcher. Move it away first."
    }
    foreach ($old in $oldCmds) {
        if (Test-Path -LiteralPath (Join-Path $launcher $old.Name)) {
            throw 'Launcher holds a file with the name of an old launcher .cmd, which would block moving the .cmd into Launcher.previous. Move that file out of Launcher first.'
        }
    }
    $version = Get-DeployVersion -RepositoryPath $RepositoryPath
    if (-not $PSCmdlet.ShouldProcess($Target, "Deploy the launcher $version")) { return }

    # Everything is staged and checked first, so a failed copy changes nothing the launcher uses.
    try {
        $null = New-Item -ItemType Directory -Path $staged
        $sums = foreach ($source in $sources) {
            $name = Split-Path $source -Leaf
            '{0}  {1}' -f (Copy-DeployFile -Source $source -Destination (Join-Path $staged $name)), $name
        }
        foreach ($name in $KeptFiles) {
            $kept = Join-Path $launcher $name
            if (Test-Path -LiteralPath $kept -PathType Leaf) { $null = Copy-DeployFile -Source $kept -Destination (Join-Path $staged $name) }
        }
        [IO.File]::WriteAllText((Join-Path $staged 'SHA256SUMS'), (($sums -join "`n") + "`n"), [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $staged 'VERSION'), "$version`n", [Text.Encoding]::ASCII)
        $null = Copy-DeployFile -Source $cmdSource -Destination $cmdStaged
    } catch {
        throw "Staging failed and the stick's launcher is unchanged. Remove $leftovers, then deploy again: $($_.Exception.Message)"
    }

    try {
        Rename-DeployItem -Path $launcher -NewName 'Launcher.previous'
    } catch {
        throw "Launcher could not be renamed, so the stick's launcher is unchanged. A window, console or program probably has the Launcher folder or a file in it open: close it, remove $leftovers, then deploy again. $($_.Exception.Message)"
    }
    try {
        Rename-DeployItem -Path $staged -NewName 'Launcher'
    } catch {
        $reason = $_.Exception.Message
        try {
            Rename-DeployItem -Path $previous -NewName 'Launcher'
        } catch {
            throw "Launcher is missing: Launcher.previous holds the stick's launcher, settings and log. Rename Launcher.previous back to Launcher, remove $leftovers, then deploy again. $reason"
        }
        throw "Launcher.new could not take the place of Launcher, so Launcher is back as it was. Remove $leftovers, then deploy again. $reason"
    }
    try {
        foreach ($old in $oldCmds) { Move-Item -LiteralPath $old.FullName -Destination (Join-Path $previous $old.Name) }
        Rename-DeployItem -Path $cmdStaged -NewName $CmdName
    } catch {
        throw "The new launcher is in Launcher, but its .cmd is not in place yet. Move the old launcher .cmd files at the stick's root into Launcher.previous, then rename '$CmdName.new' to '$CmdName'. $($_.Exception.Message)"
    }
    [pscustomobject]@{ Version = $version; MovedCmdCount = $oldCmds.Count }
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $Target) { throw 'Give -Target, the folder on the stick that holds the Launcher folder.' }
        $done = Invoke-PvmDeploy -RepositoryPath (Split-Path $PSScriptRoot -Parent) -Target $Target
        if ($done) {
            Write-Output "Deploy-PortableVM: deployed $($done.Version). $($done.MovedCmdCount) old launcher .cmd file(s) moved into Launcher.previous."
        }
        exit 0
    } catch {
        Write-Output "Deploy-PortableVM: $($_.Exception.Message)"
        exit 1
    }
}
