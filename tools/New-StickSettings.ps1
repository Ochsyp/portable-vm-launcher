# -------------------------------------------------------
#                   NEW STICK SETTINGS
# -------------------------------------------------------
#
# Write LauncherData\settings.psd1 for a stick from the stick itself and its VM files, or compare
# what it would write with the settings that are there. Run it in Windows PowerShell 5.1 from a
# clone, with the stick plugged in:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\New-StickSettings.ps1 -Target X:\
# -Target is the folder that holds, or is to hold, Launcher and LauncherData; without it the tool
# takes the one folder with a Launcher folder at a drive's root or one level below, so a new stick
# without a launcher needs -Target. It reads the stick's identity as the launcher checks it (the
# MBR signature, the number of 512-byte sectors and the Data partition that holds the folder),
# finds the one .vmx, .vbox and VirtualBox.xml below the folder, or those that -VMwareVmx,
# -VirtualBoxVbox and -VirtualBoxHome name, and checks with the launcher's own module that the
# settings pass its checks and that each VM file attaches one raw disk on the stick. The disk files
# and the VM's UUID are not written: the launcher reads them from the .vmx and the .vbox.
# It writes the file only when there is none, through the launcher's safe write, and never
# replaces one. With -Compare it writes nothing on the stick: it writes the file it would make to
# a run folder below %LOCALAPPDATA%\PortableVM\setup on this PC and names the keys that differ
# from the stick's settings, also a disk file or UUID there that the VM's files contradict.
# The tool also reports whether host I/O cache is on for the VirtualBox controller that holds the
# stick disk; with it off, VirtualBox takes the stick's volumes away from Windows. With
# -TurnOnHostIOCache it switches it on: one attribute in the .vbox, through the safe write, with
# the launcher's copies of the .vbox below LauncherData\backups, and only while VirtualBox and its
# background service are closed and the VM has no saved state and no snapshots. That is the one
# change it makes on the stick besides a new settings file, also with -Compare.
# It needs no administrator rights, runs no program and starts no VM. Each line names a check and
# a kind, a yes or no, a count or a key's name, never a value from the stick. The last line is
# "RESULT: WRITTEN", "SAME", "DIFFERENT", "NOT WRITTEN - <why>" or "FAILED - <why>", with exit
# code 0 (written, same), 1 (different, not written) or 2 (failed).

[CmdletBinding()]
param(
    [string]$Target,
    [switch]$Compare,
    [string]$VMwareVmx,
    [string]$VirtualBoxVbox,
    [string]$VirtualBoxHome,
    [string]$OutputRoot,
    [switch]$TurnOnHostIOCache
)

$ErrorActionPreference = 'Stop'
# The stick-check tool's stick search and stops are shared; dot-sourcing it sets its own
# parameters to their defaults, so this script's are kept aside.
$setupParameters = @{
    Target = $Target; Compare = $Compare; VMwareVmx = $VMwareVmx; VirtualBoxVbox = $VirtualBoxVbox; VirtualBoxHome = $VirtualBoxHome; OutputRoot = $OutputRoot
    TurnOnHostIOCache = $TurnOnHostIOCache
}
. (Join-Path $PSScriptRoot 'Compare-StickDryRun.ps1')

# Print the line $Text and keep it for the result.
function Add-SetupLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $script:SetupOutput.Add($Text)
    Write-Host $Text
}

# Return the exception for a refusal of the tool: the stick or its VM files do not fit, so it
# writes nothing. $Reason names no value from the stick.
function ConvertTo-SetupRefusal {
    [CmdletBinding()]
    [OutputType([Exception])]
    param([Parameter(Mandatory)][string]$Reason)
    $exception = New-Object InvalidOperationException $Reason
    $exception.Data['SetupRefusal'] = $true
    $exception
}

# Write the bytes $Bytes to the file $Path, in the tool's run folder on this PC.
function Save-SetupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

# Switch host I/O cache on for the storage controller $Controller of the .vbox $Vbox on the stick
# folder $Root: its useHostIOCache from "false" to "true" and nothing else, through the safe write
# with the launcher's copies below $Backups, as a start keeps them, logging a failure to $LogPath.
# Throws a refusal, changing nothing, while VirtualBox or its background service runs, when the
# VM has a saved state or snapshots, when a write of the .vbox or of a copy did not finish, or when
# the controller's entry is not one start tag that says "false" once.
function Set-SetupHostIOCache {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Backups,
        [Parameter(Mandatory)][string]$Vbox,
        [Parameter(Mandatory)][string]$Controller,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (Test-PvmVirtualBoxOpen) { throw (ConvertTo-SetupRefusal -Reason 'host I/O cache: VirtualBox or its background service is running; close every VirtualBox window, wait a minute, then run the tool again') }
    $state = (Get-PvmVirtualBoxState -Path $Vbox).State
    if ($state -eq 'Saved') { throw (ConvertTo-SetupRefusal -Reason 'host I/O cache: the VM has a saved state in VirtualBox, which needs the same hardware to resume') }
    if ($state -ne 'NotSaved') { throw (ConvertTo-SetupRefusal -Reason 'host I/O cache: the tool cannot tell from the .vbox whether the VM has a saved state in VirtualBox') }
    $copy = @{ Root = $Root; Backups = $Backups; Path = $Vbox }
    $first = Get-PvmBackupPath @copy -Suffix '.launcher-backup'
    $previous = Get-PvmBackupPath @copy -Suffix '.previous.launcher-backup'
    if ((Get-PvmLeftoverProblem -Path $Vbox) -or (Get-PvmLeftoverProblem -Path $first) -or (Get-PvmCopyLeftoverProblem -Path $previous -Of $Vbox)) {
        throw (ConvertTo-SetupRefusal -Reason 'host I/O cache: a write of the .vbox or of a copy of it did not finish; start the VM through the launcher once to be asked about it')
    }
    $bytes = [IO.File]::ReadAllBytes($Vbox)
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    $text = $strict.GetString($bytes)
    if ($text -match '<Snapshot\b') { throw (ConvertTo-SetupRefusal -Reason 'host I/O cache: the VM has snapshots, which hold copies of the controller; switch it on in VirtualBox instead') }
    $name = [Security.SecurityElement]::Escape($Controller)
    $tags = @([regex]::Matches($text, '<StorageController\b[^>]*>') | Where-Object { $_.Value -match ('\sname="' + [regex]::Escape($name) + '"') })
    $off = if ($tags.Count -eq 1) { @([regex]::Matches($tags[0].Value, '\suseHostIOCache="false"')) } else { @() }
    if ($off.Count -ne 1) { throw (ConvertTo-SetupRefusal -Reason 'host I/O cache: the controller''s entry in the .vbox is not as the tool expects; switch it on in VirtualBox instead') }
    $tag = $tags[0]
    $newTag = $tag.Value.Remove($off[0].Index, $off[0].Length).Insert($off[0].Index, ' useHostIOCache="true"')
    $new = $text.Remove($tag.Index, $tag.Length).Insert($tag.Index, $newTag)
    Assert-PvmRewritable -Path $Vbox
    if ([IO.File]::Exists($previous)) { Assert-PvmRewritable -Path $previous }
    if (-not $PSCmdlet.ShouldProcess($Vbox, 'Switch host I/O cache on for the controller that holds the stick disk')) { return }
    $change = [pscustomobject]@{
        Path = $Vbox; Old = $bytes; New = $strict.GetBytes($new); FirstBackup = $first; PreviousBackup = $previous; Disarm = $false
        Action = 'Switch host I/O cache on for the controller that holds the stick disk'
    }
    Save-PvmFileChange -Change $change -LogPath $LogPath
}

# Return the folders at a drive's root or one level below that hold Launcher\Start-PortableVM.ps1,
# settings or not, but not the clone $RepositoryPath.
function Find-SetupStick {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    foreach ($root in @(Get-CompareDriveRoot)) {
        $folders = @($root) + @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($folder in $folders) {
            if ((Test-Path -LiteralPath (Join-Path $folder 'Launcher\Start-PortableVM.ps1') -PathType Leaf -ErrorAction SilentlyContinue) -and
                -not (Test-CompareBelow -Path $folder -Folder $RepositoryPath)) { $folder }
        }
    }
}

# Return the paths, relative to the stick folder $Root, of the files named *$Extension (or named
# $Name) below it, outside the launcher's own folders and the folders Windows keeps there.
function Find-SetupFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Extension,
        [string]$Name
    )
    $own = @('Launcher', 'Launcher.new', 'Launcher.previous', 'Launcher.previous.remove', 'LauncherData', 'LauncherData.new') + $CompareSkippedNames
    $below = $Root.TrimEnd('\') + '\'
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object { $own -notcontains $_.Name })) {
        $files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue) } else { @($item) }
        foreach ($file in $files) {
            if (($Extension -and $file.Extension -eq $Extension) -or ($Name -and $file.Name -eq $Name)) { $file.FullName.Substring($below.Length) }
        }
    }
}

# Return the relative path of the VM file that the parameter $Given names, with \ as separator,
# or else the one file that $Found holds. Throws a refusal when $Given names no such file below
# the stick folder $Root, or when $Found holds more or fewer than one; $What words the files and
# $Parameter names the parameter. With -Folder, the folder of the found file is returned.
function Select-SetupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyString()][string]$Given,
        [AllowEmptyCollection()][string[]]$Found = @(),
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Parameter,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Extension,
        [switch]$Folder
    )
    if ($Given) {
        $value = $Given.Replace('/', '\').TrimEnd('\')
        $exists = if ($Extension) { Test-Path -LiteralPath (Join-PvmStickPath -Root $Root -Path $value) -PathType Leaf } else { Test-Path -LiteralPath (Join-PvmStickPath -Root $Root -Path $value) -PathType Container }
        if ((Get-PvmPathProblem -Value $value -Extension $Extension) -or -not $exists) { throw (ConvertTo-SetupRefusal -Reason "$Parameter names no $What below the stick folder") }
        return $value
    }
    if ($Found.Count -ne 1) { throw (ConvertTo-SetupRefusal -Reason "found $($Found.Count) $What files below the stick folder; name $(if ($Folder) { 'VirtualBox''s home folder' } else { 'the VM''s' }) with $Parameter") }
    if ($Folder) {
        $parent = Split-Path $Found[0]
        if (-not $parent) { throw (ConvertTo-SetupRefusal -Reason "$What lies in the stick folder itself; VirtualBox's home must be a folder below it") }
        return $parent
    }
    $Found[0]
}

# Return the text of the settings $Settings, an ordered hashtable of strings and numbers, as the
# tool writes them: a comment, then one key per line, with CRLF line endings.
function ConvertTo-SetupText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Settings)
    $lines = @(
        '# Written by tools\New-StickSettings.ps1 from the stick and its VM files. Every setting is in'
        '# examples\settings.example.psd1. The launcher reads the disk files and the VM''s UUID from the'
        '# .vmx and the .vbox, so they are not set here.'
        '@{'
    )
    foreach ($key in $Settings.Keys) {
        $value = $Settings[$key]
        $text = if ($value -is [string]) { "'" + $value.Replace("'", "''") + "'" } else { "$value" }
        $lines += "    $key = $text"
    }
    (@($lines) + '}' + '') -join "`r`n"
}

# Return whether the setting $Key holds the same value in $Left and $Right: paths without case and
# with either slash, the signature and UUID without case, numbers as numbers.
function Test-SetupSame {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Left,
        [AllowNull()]$Right
    )
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    $kind = (@(Get-PvmSettingSchema) | Where-Object { $_.Name -eq $Key }).Kind
    switch ($kind) {
        'Path' { return [string]::Equals("$Left".Replace('/', '\').TrimEnd('\'), "$Right".Replace('/', '\').TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }
        { $_ -in 'Signature', 'Uuid' } { return [string]::Equals("$Left", "$Right", [StringComparison]::OrdinalIgnoreCase) }
        { $_ -in 'Count', 'Schema' } { try { return ([int64]$Left -eq [int64]$Right) } catch { return $false } }
    }
    "$Left" -ceq "$Right"
}

# Read the stick folder $Target ('' to find it) and its VM files with the launcher's module from
# the clone $RepositoryPath, as the header of this file describes, at the time $Now; write the
# settings, or with -Compare compare them. Returns ExitCode and Lines, what it printed.
function Invoke-StickSetup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [AllowEmptyString()][string]$Target = '',
        [switch]$Compare,
        [AllowEmptyString()][string]$VMwareVmx = '',
        [AllowEmptyString()][string]$VirtualBoxVbox = '',
        [AllowEmptyString()][string]$VirtualBoxHome = '',
        [AllowEmptyString()][string]$OutputRoot = '',
        [switch]$TurnOnHostIOCache,
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $script:SetupOutput = New-Object System.Collections.Generic.List[string]
    $exitCode = 2
    try {
        # Without -Force, so a module the caller loaded (and its test doubles) stays as it is.
        $null = Import-Module -Name (Join-Path $RepositoryPath 'src\PortableVM.psm1') -Global -DisableNameChecking
        if (-not $Target) {
            $found = @(Find-SetupStick -RepositoryPath $RepositoryPath)
            if ($found.Count -ne 1) { throw (ConvertTo-CompareStop -Reason "found $($found.Count) folders with a Launcher folder at a drive's root or one level below; give -Target") }
            $Target = $found[0]
            Add-SetupLine '  stick folder: found by its Launcher folder'
        } else {
            if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw (ConvertTo-CompareStop -Reason 'the -Target folder does not exist') }
            Add-SetupLine '  stick folder: given'
        }
        $Target = [IO.Path]::GetFullPath($Target)
        if ($Target.Length -gt 3) { $Target = $Target.TrimEnd('\') }
        # A new stick has no launcher yet: the deploy tool needs the settings first.
        $launcher = Join-Path $Target 'Launcher'
        $paths = Get-PvmDataPath -LauncherPath $launcher
        $there = Test-Path -LiteralPath $paths.Settings
        if (-not $Compare -and $there) { throw (ConvertTo-SetupRefusal -Reason 'LauncherData\settings.psd1 is there already, and the tool never replaces it; compare them with -Compare') }
        if ($Compare -and -not $there) { throw (ConvertTo-CompareStop -Reason 'the stick has no LauncherData\settings.psd1 to compare with') }

        # The stick, as the launcher checks it.
        $location = Get-PvmStickLocation -LauncherPath $launcher -Root $Target
        if (-not $location) { throw (ConvertTo-CompareStop -Reason 'the tool finds the stick''s disk only by a drive letter on Windows') }
        try { $stick = Get-PvmStickDevice -Location $location -Names @{ VM = $null; Guest = $null } }
        catch { throw (ConvertTo-CompareStop -Reason 'Windows did not say which disk the folder is on') }
        $disk = $stick.Disk
        if ($disk.PartitionStyle -ne 'MBR' -or $disk.LogicalSectorSize -ne 512) { throw (ConvertTo-SetupRefusal -Reason 'the stick is no MBR disk with 512-byte sectors, which the launcher needs') }
        if ($disk.IsBoot -or $disk.IsSystem) { throw (ConvertTo-SetupRefusal -Reason 'the disk the folder is on is this PC''s Windows disk') }
        Add-SetupLine '  stick identity: read'

        # The VM files below the stick folder.
        $vmxFound = @(Find-SetupFile -Root $Target -Extension '.vmx')
        $vboxFound = @(Find-SetupFile -Root $Target -Extension '.vbox')
        $homeFound = @(Find-SetupFile -Root $Target -Name 'VirtualBox.xml')
        Add-SetupLine "  .vmx files below the stick folder: $($vmxFound.Count)"
        Add-SetupLine "  .vbox files below the stick folder: $($vboxFound.Count)"
        Add-SetupLine "  VirtualBox.xml files below the stick folder: $($homeFound.Count)"
        $settings = [ordered]@{
            SchemaVersion      = 2
            StickMbrSignature  = Get-PvmDiskSignature -Disk $disk
            StickSectors       = [int64]($disk.Size / 512)
            VmSectors          = [int64](($stick.Partition.Offset + $stick.Partition.Size) / 512)
            DataPartitionStart = [int64]($stick.Partition.Offset / 512)
            VirtualBoxHome     = Select-SetupPath -Root $Target -Given $VirtualBoxHome -Found $homeFound -What 'VirtualBox.xml' -Parameter '-VirtualBoxHome' -Extension '' -Folder
            VirtualBoxVbox     = Select-SetupPath -Root $Target -Given $VirtualBoxVbox -Found $vboxFound -What '.vbox' -Parameter '-VirtualBoxVbox' -Extension '.vbox'
            VMwareVmx          = Select-SetupPath -Root $Target -Given $VMwareVmx -Found $vmxFound -What '.vmx' -Parameter '-VMwareVmx' -Extension '.vmx'
        }
        $plain = @{}
        foreach ($key in $settings.Keys) { $plain[$key] = $settings[$key] }
        $problems = @(Test-PvmSetting -Settings $plain)
        if ($problems.Count) { throw (ConvertTo-SetupRefusal -Reason "the settings would not pass the launcher's checks: $(@($problems | ForEach-Object { ($_ -split ':')[0] }) -join ', ')") }
        Add-SetupLine '  the settings pass the launcher''s checks: yes'

        # The VM's own files, read as a start with these settings reads them.
        $context = [pscustomobject]@{
            Settings = (Merge-PvmSetting -Settings $plain); Root = $Target; Backups = $paths.Backups; Location = $location
            Names = @{ VM = 'the VM'; Guest = 'the guest' }; VmFiles = $null
        }
        $context.VmFiles = New-PvmVmFileRecord -Context $context
        Resolve-PvmVMwareFile -Context $context
        Resolve-PvmVirtualBoxFile -Context $context
        $files = $context.VmFiles
        $words = @{
            Setting = 'the settings name another file'; None = 'no raw-disk file is attached'; Several = 'more than one raw-disk file is attached'
            Outside = 'it is not below the stick folder'; Uuid = 'the settings name another UUID'; Unlisted = 'it attaches a disk that its media registry does not list'
            NoMachine = 'it has no Machine element'
        }
        $vmware = if (-not $files.VMwareRead) { 'unknown, since the .vmx cannot be read or is not complete' } elseif ($files.VMwareKind) { "no, $($words[$files.VMwareKind])" } else { 'yes' }
        $virtualBox = if (-not $files.VirtualBoxRead) { 'unknown, since the .vbox cannot be read' } elseif ($files.VirtualBoxKind) { "no, $($words[$files.VirtualBoxKind])" } else { 'yes' }
        Add-SetupLine "  VMware disk file as the .vmx attaches it: $vmware"
        Add-SetupLine "  VirtualBox disk file and UUID as the .vbox has them: $virtualBox"
        if ($vmware -ne 'yes') { throw (ConvertTo-SetupRefusal -Reason "the VMware disk file as the .vmx attaches it: $($vmware -replace '^no, ', '')") }
        if ($virtualBox -ne 'yes') { throw (ConvertTo-SetupRefusal -Reason "the VirtualBox disk file and UUID as the .vbox has them: $($virtualBox -replace '^no, ', '')") }

        # With -Compare, the disk files and the UUID that the stick's settings name too, which the
        # VM's files must not contradict; one they do is a difference to report.
        $existing = @{}
        $contradicted = @()
        if ($Compare) {
            try { $existing = Import-PvmDataFile -Path $paths.Settings }
            catch { throw (ConvertTo-CompareStop -Reason 'the stick''s LauncherData\settings.psd1 cannot be read') }
            $named = Merge-PvmSetting -Settings $plain
            foreach ($key in 'VMwareDisk', 'VirtualBoxDisk', 'VirtualBoxVmUuid') {
                if ($existing.ContainsKey($key) -and $existing[$key] -is [string]) { $named[$key] = $existing[$key] }
            }
            $context.Settings = $named
            $context.VmFiles = New-PvmVmFileRecord -Context $context
            Resolve-PvmVMwareFile -Context $context
            Resolve-PvmVirtualBoxFile -Context $context
            if ($context.VmFiles.VMwareKind) { $contradicted += 'VMwareDisk' }
            if ($context.VmFiles.VirtualBoxKind -eq 'Uuid') { $contradicted += 'VirtualBoxVmUuid' }
            elseif ($context.VmFiles.VirtualBoxKind) { $contradicted += 'VirtualBoxDisk' }
        }

        # Host I/O cache for the controller that holds the stick disk, switched on when asked.
        if (-not $OutputRoot) { $OutputRoot = Join-Path $env:LOCALAPPDATA 'PortableVM\setup' }
        $run = Join-Path $OutputRoot $Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $cache = if ($files.HostIOCache -eq 'true') { 'yes' } else { 'no' }
        $cacheNote = ''
        if ($cache -eq 'no') {
            if ($TurnOnHostIOCache) {
                $null = [IO.Directory]::CreateDirectory($run)
                $vbox = Join-PvmStickPath -Root $Target -Path $settings['VirtualBoxVbox']
                Set-SetupHostIOCache -Root $Target -Backups $paths.Backups -Vbox $vbox -Controller $files.Controller -LogPath (Join-Path $run 'setup.log')
                $context.Settings = Merge-PvmSetting -Settings $plain
                $context.VmFiles = New-PvmVmFileRecord -Context $context
                Resolve-PvmVirtualBoxFile -Context $context
                if ($context.VmFiles.HostIOCache -ne 'true') { throw (ConvertTo-CompareStop -Reason 'the .vbox does not read as changed; check it against its copies below LauncherData\backups') }
                $cache = 'yes, switched on now'
            } else {
                $cacheNote = '; host I/O cache is off for the stick disk, which -TurnOnHostIOCache switches on'
            }
        }
        Add-SetupLine "  VirtualBox host I/O cache on for the stick disk: $cache"

        $text = ConvertTo-SetupText -Settings $settings
        $bytes = if ($text -match '[^\x00-\x7F]') { [byte[]](@(0xEF, 0xBB, 0xBF) + (New-Object System.Text.UTF8Encoding $false).GetBytes($text)) } else { [Text.Encoding]::ASCII.GetBytes($text) }
        if ($Compare) {
            $differ = @(@($settings.Keys | Where-Object { -not $existing.ContainsKey($_) -or -not (Test-SetupSame -Key $_ -Left $settings[$_] -Right $existing[$_]) }) + $contradicted | Sort-Object -Unique)
            $own = @($existing.Keys | Where-Object { -not $settings.Contains($_) } | Sort-Object)
            $null = [IO.Directory]::CreateDirectory($run)
            Save-SetupFile -Path (Join-Path $run 'settings.psd1') -Bytes $bytes
            Add-SetupLine "  keys that differ: $(if ($differ.Count) { $differ -join ', ' } else { 'none' })"
            Add-SetupLine "  keys set only in the stick's settings: $(if ($own.Count) { $own -join ', ' } else { 'none' })"
            if ($differ.Count) {
                Add-SetupLine "RESULT: DIFFERENT - $($differ -join ', ')$cacheNote"
                $exitCode = 1
            } else {
                Add-SetupLine "RESULT: SAME - every key the tool would write equals the stick's settings$cacheNote"
                $exitCode = 0
            }
        } else {
            $null = [IO.Directory]::CreateDirectory($paths.Data)
            try { $null = Write-PvmFile -Path $paths.Settings -Bytes $bytes }
            catch {
                # Settings that another run wrote meanwhile are never replaced either.
                if ("$($_.Exception.Data['PvmWrite'])" -eq 'Exists') { throw (ConvertTo-SetupRefusal -Reason 'LauncherData\settings.psd1 is there already, and the tool never replaces it; compare them with -Compare') }
                throw
            }
            Add-SetupLine "RESULT: WRITTEN - LauncherData\settings.psd1$cacheNote"
            $exitCode = 0
        }
    } catch {
        if ($_.Exception.Data['SetupRefusal']) {
            Add-SetupLine "RESULT: NOT WRITTEN - $($_.Exception.Message)"
            $exitCode = 1
        } else {
            $reason = if ($_.Exception.Data['CompareStop']) { $_.Exception.Message }
            elseif (Get-Command -Name Get-PvmErrorCause -ErrorAction SilentlyContinue) { "unexpected error: $(Get-PvmErrorCause -ErrorRecord $_)" }
            else { "unexpected error of type $($_.Exception.GetType().Name)" }
            Add-SetupLine "RESULT: FAILED - $reason"
            $exitCode = 2
        }
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $script:SetupOutput.ToArray() }
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    $Target = $setupParameters.Target
    if ($Target -and (Test-Path -LiteralPath $Target -PathType Container)) { $Target = Convert-Path -LiteralPath $Target }
    $result = Invoke-StickSetup -RepositoryPath (Split-Path $PSScriptRoot -Parent) -Target $Target -Compare:$setupParameters.Compare -VMwareVmx $setupParameters.VMwareVmx `
        -VirtualBoxVbox $setupParameters.VirtualBoxVbox -VirtualBoxHome $setupParameters.VirtualBoxHome -OutputRoot $setupParameters.OutputRoot `
        -TurnOnHostIOCache:$setupParameters.TurnOnHostIOCache
    exit $result.ExitCode
}
