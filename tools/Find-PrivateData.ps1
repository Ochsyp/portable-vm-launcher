# -------------------------------------------------------
#                   FIND PRIVATE DATA
# -------------------------------------------------------
#
# Looks for the values of the real, untracked settings files, LauncherData\settings.psd1 and the
# older Launcher\settings.psd1 in the clone or the files -SettingsPath names, and for the strings
# listed in .git/info/privacy-denylist, in what GitHub would show: the contents and names of the
# files in git's index and, with -History, of every commit reachable from any ref, the commit
# messages and the ref names. Prints the setting's name and where it was found, never the value.
# Run it in Windows PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Find-PrivateData.ps1 -History
# .githooks/pre-push runs it like that before every push. -RepositoryPath checks another clone
# than the one this script is in. Exits 0 when nothing is found or there is nothing to look for,
# 1 on a match, 2 when the check cannot run.

[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [string[]]$SettingsPath,
    [switch]$History
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty in a param() default, so it is read here.
if (-not $RepositoryPath) { $RepositoryPath = Split-Path $PSScriptRoot -Parent }

# The settings that identify one stick and one VM. The path settings count by their folder and
# file names; the default folder names below are the same on every stick. Numbers shorter than
# seven digits, such as a partition start of 2048, are common and identify nothing.
$IdentityKeys = @('StickMbrSignature', 'StickSectors', 'VmSectors', 'DataPartitionStart', 'VirtualBoxVmUuid')
$PathKeys = @('VirtualBoxHome', 'VirtualBoxVbox', 'VirtualBoxDisk', 'VMwareVmx', 'VMwareDisk')
$GenericNames = @('VirtualBox', 'VMware')
# The names of the VM and the guest system count unless they are the neutral defaults.
$NameKeys = @('VmDisplayName', 'GuestName')
$NeutralNames = @('the VM', 'the guest')
$MinimumNumberDigits = 7

# Run git in the repository and return its output lines. git writes UTF-8, so the console's
# output encoding is UTF-8 during the call; git's stderr joins the output, which in Windows
# PowerShell 5.1 needs $ErrorActionPreference Continue around the call. Throws when git's exit
# code is not in $AllowedExitCodes, without git's output, which may spell out a value.
function Invoke-Git {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0)
    )
    $previousPreference = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }
        catch { Write-Verbose "The console encoding stays $($previousEncoding.WebName): $($_.Exception.Message)" }
        $output = @(& git -C $RepositoryPath -c core.quotePath=false @Arguments 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } finally {
        try { [Console]::OutputEncoding = $previousEncoding }
        catch { Write-Verbose "The console encoding was not restored: $($_.Exception.Message)" }
        $ErrorActionPreference = $previousPreference
    }
    if ($AllowedExitCodes -notcontains $exitCode) { throw "git $($Arguments[0]) failed with exit code $exitCode." }
    $output
}

# Return name/value pairs to look for: from each settings table in $Settings the identity
# settings as written, each folder and file name of the path settings with and without its
# extension, and the VM and guest names unless they are the neutral defaults; then each denylist
# line. Values shorter than four characters, and numbers shorter than $MinimumNumberDigits, are
# skipped as too common to mean anything.
function Get-PrivateValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [hashtable[]]$Settings,
        [string[]]$Denylist
    )
    $pairs = @()
    foreach ($table in @($Settings | Where-Object { $_ })) {
        foreach ($key in $IdentityKeys) {
            if ($table.ContainsKey($key)) { $pairs += [pscustomobject]@{ Name = $key; Value = "$($table[$key])".Trim() } }
        }
        foreach ($key in $PathKeys) {
            if (-not $table.ContainsKey($key)) { continue }
            foreach ($segment in ("$($table[$key])" -split '[\\/]')) {
                foreach ($name in @($segment, [IO.Path]::GetFileNameWithoutExtension($segment))) {
                    if ($GenericNames -notcontains $name) { $pairs += [pscustomobject]@{ Name = $key; Value = $name.Trim() } }
                }
            }
        }
        foreach ($key in $NameKeys) {
            if ($table.ContainsKey($key) -and $NeutralNames -notcontains "$($table[$key])".Trim()) {
                $pairs += [pscustomobject]@{ Name = $key; Value = "$($table[$key])".Trim() }
            }
        }
    }
    foreach ($line in $Denylist) {
        $pairs += [pscustomobject]@{ Name = 'privacy-denylist'; Value = $line }
    }
    $pairs | Where-Object {
        if ($_.Value -match '^\d+$') { $_.Value.Length -ge $MinimumNumberDigits } else { $_.Value.Length -ge 4 }
    } | Sort-Object Name, Value -Unique
}

# Return whether $Text holds $Value, compared without case. A number counts only as a whole
# number, not as part of a longer one.
function Test-ContainsValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Text,
        [Parameter(Mandatory)][string]$Value
    )
    if ($Value -match '^\d+$') { return [regex]::IsMatch($Text, '(^|\D)' + $Value + '(\D|$)') }
    $Text.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

# Return where git's index holds $Value, in a file's contents or name, and with -History where
# the reachable commits, their messages, the file names in the history and the ref names hold
# it, compared as Test-ContainsValue does. A place that spells out the value itself shows
# <value> in its stead.
function Find-Value {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Value,
        [string[]]$Revisions,
        [string[]]$IndexPaths,
        [string[]]$HistoryPaths,
        [string[]]$RefNames
    )
    $isNumber = $Value -match '^\d+$'
    $match = @('-I', '-F', '-i', '-l')
    if ($isNumber) { $match += '-w' }
    $match += @('-e', $Value)
    $places = @()
    $places += @(Invoke-Git -Arguments (@('grep', '--cached') + $match) -AllowedExitCodes 0, 1 | ForEach-Object { "index: $_" })
    $places += @($IndexPaths | Where-Object { Test-ContainsValue -Text $_ -Value $Value } | ForEach-Object { "index path: $_" })
    if ($History) {
        # Revisions go to git grep in batches, so the command line stays short.
        for ($i = 0; $i -lt $Revisions.Count; $i += 100) {
            $batch = $Revisions[$i..([Math]::Min($i + 99, $Revisions.Count - 1))]
            $places += @(Invoke-Git -Arguments (@('grep') + $match + $batch) -AllowedExitCodes 0, 1 | ForEach-Object { "commit $_" })
        }
        $grepMessage = if ($isNumber) { @('-E', "--grep=(^|[^0-9])$Value([^0-9]|$)") } else { @('-F', "--grep=$Value") }
        $places += @(Invoke-Git -Arguments (@('log', '--all', '-i') + $grepMessage + '--format=%h') |
            Where-Object { $_ } | ForEach-Object { "message of commit $_" })
        $places += @($HistoryPaths | Where-Object { Test-ContainsValue -Text $_ -Value $Value } | ForEach-Object { "file name in the history: $_" })
        $places += @($RefNames | Where-Object { Test-ContainsValue -Text $_ -Value $Value } | ForEach-Object { 'a ref name' })
    }
    $places | ForEach-Object { [regex]::Replace($_, [regex]::Escape($Value), '<value>', 'IgnoreCase') }
}

try {
    if (-not $SettingsPath) {
        $SettingsPath = @((Join-Path $RepositoryPath 'LauncherData\settings.psd1'), (Join-Path $RepositoryPath 'Launcher\settings.psd1'))
    }
    $settings = @($SettingsPath | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object {
            Import-PowerShellDataFile -LiteralPath $_
        })
    $gitDir = @(Invoke-Git -Arguments @('rev-parse', '--absolute-git-dir'))[0]
    $denylistPath = Join-Path $gitDir 'info\privacy-denylist'
    $denylist = @()
    if (Test-Path -LiteralPath $denylistPath -PathType Leaf) {
        # Read as UTF-8, with or without a BOM, the way git and privacy-scan read it.
        $denylist = @(Get-Content -LiteralPath $denylistPath -Encoding UTF8 | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    $values = @(Get-PrivateValue -Settings $settings -Denylist $denylist)
    if ($values.Count -eq 0) {
        Write-Output 'Find-PrivateData: no settings file and no denylist, so there is nothing to look for.'
        exit 0
    }
    $indexPaths = @(Invoke-Git -Arguments @('ls-files'))
    $revisions = @()
    $historyPaths = @()
    $refNames = @()
    if ($History) {
        $revisions = @(Invoke-Git -Arguments @('rev-list', '--all') | Where-Object { $_ })
        $historyPaths = @(Invoke-Git -Arguments @('log', '--all', '--name-only', '--format=') | Where-Object { $_ } | Sort-Object -Unique)
        $refNames = @(Invoke-Git -Arguments @('for-each-ref', '--format=%(refname)') | Where-Object { $_ })
    }

    # Several values of one setting can sit in one place, so each setting and place shows once.
    $findings = @(@(foreach ($pair in $values) {
                foreach ($place in @(Find-Value -Value $pair.Value -Revisions $revisions -IndexPaths $indexPaths -HistoryPaths $historyPaths -RefNames $refNames)) {
                    "a value of $($pair.Name) is in $place"
                }
            }) | Sort-Object -Unique)
    $scope = if ($History) { 'the index and the whole history' } else { 'the index' }
    if ($findings.Count -gt 0) {
        $findings | ForEach-Object { Write-Output "Find-PrivateData: $_" }
        Write-Output "Find-PrivateData: $($findings.Count) finding(s) in $scope."
        exit 1
    }
    Write-Output "Find-PrivateData: none of $($values.Count) values is in $scope."
    exit 0
} catch {
    # The message can quote a line of the settings file, so it appears only with -Verbose.
    Write-Verbose $_.Exception.Message
    Write-Output "Find-PrivateData: the check could not run ($($_.Exception.GetType().Name)); run it with -Verbose for the reason."
    exit 2
}
