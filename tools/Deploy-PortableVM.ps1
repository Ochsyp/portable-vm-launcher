# -------------------------------------------------------
#                  DEPLOY PORTABLE VM
# -------------------------------------------------------
#
# Copies the launcher from this clone to a stick. -Target is the folder on the stick's Data
# partition that holds the Launcher and LauncherData folders, for example X:\. Run it in Windows
# PowerShell 5.1:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Deploy-PortableVM.ps1 -Target X:\
# The launcher's code lives in Launcher, which each deploy replaces as a whole; the settings, the
# log and the launcher's backups live in LauncherData, which a deploy leaves alone. A deploy needs
# a LauncherData\settings.psd1 that passes the clone's settings checks. Without a Launcher folder
# it installs the launcher. Otherwise it builds Launcher.new from src\ with a VERSION from git
# describe and a SHA256SUMS of the code, and checks every copy against the clone; then Launcher
# becomes Launcher.previous, Launcher.new becomes Launcher, the old launcher .cmd files at -Target
# move into Launcher.previous and "Start VM.cmd" takes their place.
#
# A stick that still keeps its settings in Launcher\settings.psd1, as the launcher before
# LauncherData did (schema 1), needs one run with -MigrateSettings. It checks everything first and
# prints its plan. Then it writes LauncherData\settings.psd1 as schema 2 with every value and
# comment kept, adding the names -VmDisplayName and -GuestName when given; keeps a copy of the old
# file in LauncherData\backups\legacy\Launcher; moves Launcher\launcher.log to LauncherData\logs;
# and moves the copies the old launcher kept beside the VM files (*.vmdk.orig,
# *.vbox.launcher-backup, VirtualBox.xml.launcher-backup) to LauncherData\backups\legacy, where
# each descriptor copy names a disarmed device instead of a raw disk. The code swap comes last, so
# the old launcher works until then, and the same command finishes a migration that stopped.
#
# It refuses, changing nothing, while a VM runs on this PC, when the settings fail the checks, when
# Launcher.new, "Start VM.cmd.new", LauncherData.new or Launcher.previous is left from an earlier
# deploy, or when a .cmd at -Target is in the way. A migration also refuses an old settings file
# without a byte order mark whose values read differently as UTF-8 and as ANSI, and, when it
# resumes, two settings files that differ. It deletes nothing, changes no VM file and names no file
# from the stick in its output: a path below -Target in an error is left out, and -Verbose shows
# it and the copies a migration moves. When a step fails it says what is left to fix by hand.
# -WhatIf runs the checks and prints the plan only. Exits 0 when done, 1 when it refused or failed.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Target,
    [switch]$MigrateSettings,
    [string]$VmDisplayName,
    [string]$GuestName
)

$ErrorActionPreference = 'Stop'

$CodeFiles = @('Start-PortableVM.ps1', 'PortableVM.psm1')
$CmdName = 'Start VM.cmd'
# vmware-vmx% also covers the debug and stats builds of VMware's VM process.
$VmProcessFilter = "Name LIKE 'vmware-vmx%' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
# A .cmd that starts the launcher runs a .ps1 below %~dp0Launcher\, with or without a backslash
# after %~dp0.
$LauncherCmdPattern = '(?i)%~dp0\\?Launcher\\[^"\r\n]*\.ps1'
# A *.vmdk.orig of this size or more holds disk data, not a copy of a descriptor, and stays.
$MaxDescriptorBytes = 1MB

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

# Return the SHA-256 hash of the file $Path in lowercase hex. It hashes with .NET, since
# Get-FileHash returns nothing while -WhatIf is in effect, and the checks run under -WhatIf too.
function Get-DeployHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
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

# Import the launcher's module from the clone at $RepositoryPath, whose settings checks and
# settings migration the deploy uses. Throws when it cannot be loaded.
function Import-DeployModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryPath)
    try { Import-Module -Name (Join-Path $RepositoryPath 'src\PortableVM.psm1') -Force -Global -ErrorAction Stop }
    catch { throw "The clone's src\PortableVM.psm1 cannot be loaded, so the settings cannot be checked: $($_.Exception.Message)" }
}

# Return whether the hashtables $Left and $Right hold the same keys, compared without case, with
# values of the same type and text.
function Test-DeploySameValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Left,
        [Parameter(Mandatory)][hashtable]$Right
    )
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($key in $Left.Keys) {
        $other = @($Right.Keys | Where-Object { "$_" -eq "$key" })
        if ($other.Count -ne 1) { return $false }
        $a = $Left[$key]
        $b = $Right[$other[0]]
        if ($null -eq $a -or $null -eq $b) {
            if ($null -ne $a -or $null -ne $b) { return $false }
        } elseif ($a.GetType() -ne $b.GetType() -or "$a" -cne "$b") {
            return $false
        }
    }
    $true
}

# Return, sorted, the keys of the hashtables $Left and $Right, matched without case and other than
# those in $Ignore, whose values differ in type or text, or that only one of them holds.
function Get-DeployDifferentKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Left,
        [Parameter(Mandatory)][hashtable]$Right,
        [string[]]$Ignore = @()
    )
    $names = @(@($Left.Keys) + @($Right.Keys) | ForEach-Object { "$_" } | Sort-Object -Unique | Where-Object { $Ignore -notcontains $_ })
    foreach ($name in $names) {
        $a = Get-DeployValue -Values $Left -Key $name
        $b = Get-DeployValue -Values $Right -Key $name
        if ($null -eq $a -and $null -eq $b) { continue }
        if ($null -eq $a -or $null -eq $b -or $a.GetType() -ne $b.GetType() -or "$a" -cne "$b") { $name }
    }
}

# Return the text of the schema 1 settings file whose bytes are $Bytes, as the migration writes it
# on. Without a byte order mark the launcher before LauncherData read the file as ANSI, while an
# editor such as Notepad or VS Code saves it as UTF-8. When the two readings differ only in
# comments, the UTF-8 text keeps them as the editor wrote them; when a value differs, the
# migration cannot tell which one the stick uses, and this throws, naming the keys.
function Get-DeployLegacyText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $text = ConvertFrom-PvmDataFileByte -Bytes $Bytes -Legacy
    $ansi = (Get-PvmDataFileHashtable -Text $text).SafeGetValue()
    $bom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) -or
    ($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF)))
    if ($bom -or @($Bytes | Where-Object { $_ -gt 0x7F }).Count -eq 0) { return $text }
    try { $utf8 = (New-Object System.Text.UTF8Encoding $false, $true).GetString($Bytes) }
    catch { return $text }
    $keys = @()
    try { $keys = @(Get-DeployDifferentKey -Left $ansi -Right (Get-PvmDataFileHashtable -Text $utf8).SafeGetValue()) }
    catch { $keys = @('the whole file') }
    if ($keys.Count -eq 0) { return $utf8 }
    throw ("Launcher\settings.psd1 has no byte order mark, and $($keys -join ', ') read differently as UTF-8, as an editor saves it, than as ANSI, as the launcher before LauncherData read it, so nothing was changed. " +
        'Check with a dry run of that launcher which files it uses, save the file as UTF-8 with BOM or as ANSI to match, then run the same command again.')
}

# Return the value of the key $Key in the hashtable $Values, with the key matched without case, or
# $null when it has none.
function Get-DeployValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Key
    )
    foreach ($name in $Values.Keys) { if ("$name" -eq $Key) { return $Values[$name] } }
    $null
}

# Return the copies that the launcher before LauncherData kept beside the files it rewrote, in the
# folders that the path settings of each table in $Settings name below $Target; a value that
# breaks the path rule (Get-PvmPathProblem) names no folder. Move holds the copies a migration
# moves, each with its Path, its Relative path below $Target and its Kind, Descriptor (a
# *.vmdk.orig under $MaxDescriptorBytes) or VirtualBox (a *.vbox.launcher-backup or
# VirtualBox.xml.launcher-backup); Keep is the number of other *.orig and *.launcher-backup files
# there, which stay.
function Find-DeployLegacyCopy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable[]]$Settings
    )
    $root = [IO.Path]::GetFullPath($Target).TrimEnd('\') + '\'
    # The extension each path setting needs; the folder setting names its folder itself.
    $rules = [ordered]@{ VMwareDisk = '.vmdk'; VirtualBoxDisk = '.vmdk'; VirtualBoxVbox = '.vbox'; VirtualBoxHome = '' }
    $folders = @(foreach ($table in $Settings) {
            foreach ($key in $rules.Keys) {
                $value = Get-DeployValue -Values $table -Key $key
                if ($value -isnot [string] -or (Get-PvmPathProblem -Value $value -Extension $rules[$key])) { continue }
                $path = Join-Path $Target $value
                if ($rules[$key]) { Split-Path $path } else { $path }
            }
        }) | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique
    $move = @()
    $keep = 0
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -like '*.orig' -or $_.Name -like '*.launcher-backup' })) {
            $kind = ''
            if ($file.Name -like '*.vmdk.orig' -and $file.Length -lt $MaxDescriptorBytes) { $kind = 'Descriptor' }
            elseif ($file.Name -like '*.vbox.launcher-backup' -or $file.Name -eq 'VirtualBox.xml.launcher-backup') { $kind = 'VirtualBox' }
            if (-not $kind) {
                $keep++
                continue
            }
            $move += [pscustomobject]@{ Path = $file.FullName; Relative = $file.FullName.Substring($root.Length); Kind = $kind }
        }
    }
    [pscustomobject]@{ Move = $move; Keep = $keep }
}

# Return a path for the file $Path that nothing has yet: $Path itself, or its name with ' (2)',
# ' (3)' and so on before the first dot, as Explorer names copies.
function Get-DeployFreePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $folder = Split-Path $Path
    $name = Split-Path $Path -Leaf
    $dot = $name.IndexOf('.')
    $stem = if ($dot -gt 0) { $name.Substring(0, $dot) } else { $name }
    $rest = if ($dot -gt 0) { $name.Substring($dot) } else { '' }
    for ($number = 2; ; $number++) {
        $candidate = Join-Path $folder "$stem ($number)$rest"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
}

# Throw, naming no file, unless the file $Path can be opened to read, write and delete while no
# other program has it open. A migration checks each file it moves this way before its first
# change.
function Assert-DeployWriteAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $rights = [Security.AccessControl.FileSystemRights]'Read, Write, Delete'
        $stream = New-Object System.IO.FileStream $Path, ([IO.FileMode]::Open), $rights, ([IO.FileShare]::None), 4096, ([IO.FileOptions]::None)
        $stream.Dispose()
    } catch {
        Write-Verbose "Cannot open $Path to move it: $($_.Exception.Message)"
        throw 'A file that the migration moves is open in another program, or this account may not change it, so nothing was changed. Close what uses the stick and run the same command again; -Verbose names the file.'
    }
}

# Disarm the descriptor copy $Path in place (ConvertTo-PvmDisarmedDescriptorText, every other
# byte kept) and return whether it changed. The new bytes go to <Path>.pvm-tmp and are read back
# and compared, and [IO.File]::Replace then puts them in place on the same volume: Windows
# PowerShell 5.1 has no rename that replaces a file, and this tool deletes nothing. A .pvm-tmp
# left by an earlier run is overwritten.
function Set-DeployDisarmedCopy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    # ISO-8859-1 maps each byte to one character and back, so only the device names change.
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $text = $latin1.GetString([IO.File]::ReadAllBytes($Path))
    $disarmed = ConvertTo-PvmDisarmedDescriptorText -Text $text
    if ($disarmed -ceq $text) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Disarm the descriptor copy')) { return $false }
    $temporary = "$Path.pvm-tmp"
    [IO.File]::WriteAllBytes($temporary, $latin1.GetBytes($disarmed))
    if ($latin1.GetString([IO.File]::ReadAllBytes($temporary)) -cne $disarmed) { throw 'A disarmed descriptor copy did not read back as written.' }
    [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    $true
}

# Return whether the staged launcher folder $Folder holds exactly the code files $Sources, the
# SHA256SUMS $Sums and the VERSION $Version, each as this run would write it, so that a resumed
# migration can use it.
function Test-DeployStagedCode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][string]$Sums,
        [Parameter(Mandatory)][string]$Version
    )
    $expected = @($Sources | ForEach-Object { Split-Path $_ -Leaf }) + 'SHA256SUMS', 'VERSION'
    $names = @(Get-ChildItem -LiteralPath $Folder -Force | ForEach-Object { $_.Name })
    if (@(Compare-Object -ReferenceObject $expected -DifferenceObject $names).Count -gt 0) { return $false }
    foreach ($source in $Sources) {
        if ((Get-DeployHash -Path (Join-Path $Folder (Split-Path $source -Leaf))) -ne (Get-DeployHash -Path $source)) { return $false }
    }
    ([IO.File]::ReadAllText((Join-Path $Folder 'SHA256SUMS')) -ceq $Sums) -and ([IO.File]::ReadAllText((Join-Path $Folder 'VERSION')) -ceq "$Version`n")
}

# Return the plan of a migration of the stick folder $Target from schema 1, checked before any
# change and refusing what it cannot do: Bytes, the new LauncherData\settings.psd1 (ASCII, or
# UTF-8 with a BOM when it holds other characters); Values, the settings the new launcher reads;
# Copies, the copies to move (Find-DeployLegacyCopy); Log, whether Launcher\launcher.log moves;
# and the counts that the report shows. The old file is read by Get-DeployLegacyText. With
# -Resume, LauncherData is there from a migration that stopped: its settings.psd1 stays as it is,
# so it must pass the checks, hold the names given, and agree with Launcher\settings.psd1 once
# both have their defaults, apart from SchemaVersion, IsExample and the names. The copies are then
# looked for in the folders of both settings files, and Bytes is $null.
function Get-DeployMigrationPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$VmDisplayName,
        [string]$GuestName,
        [switch]$Resume
    )
    $oldSettings = Join-Path $Target 'Launcher\settings.psd1'
    $data = Join-Path $Target 'LauncherData'
    $settings = Join-Path $data 'settings.psd1'
    try {
        $text = Get-DeployLegacyText -Bytes ([IO.File]::ReadAllBytes($oldSettings))
        $old = (Get-PvmDataFileHashtable -Text $text).SafeGetValue()
    } catch {
        $reason = $_.Exception.Message
        if ($reason -like 'Launcher\settings.psd1 has no byte order mark*') { throw }
        throw "Launcher\settings.psd1 cannot be read, so nothing was changed: $reason."
    }
    $bytes = $null
    if ($Resume) {
        if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
            throw 'LauncherData is there, but without settings.psd1, so the migration cannot tell what happened. Rename LauncherData to another name, then run the same command again.'
        }
        try { $null = Import-PvmSetting -Path $settings }
        catch {
            $stop = Get-PvmStopMessage -ErrorRecord $_
            if ($null -eq $stop) { throw }
            throw "LauncherData\settings.psd1 is there from a migration that stopped, and this run keeps it, but it must pass the checks first, so nothing was changed. $stop"
        }
        $values = Import-PvmDataFile -Path $settings
        foreach ($name in 'VmDisplayName', 'GuestName') {
            $given = if ($name -eq 'VmDisplayName') { $VmDisplayName } else { $GuestName }
            if ($given -and "$(Get-DeployValue -Values $values -Key $name)" -cne $given) {
                throw "LauncherData\settings.psd1 is there from a migration that stopped, and this run keeps it, but its $name is not the one given, so nothing was changed. Set VmDisplayName and GuestName in LauncherData\settings.psd1, then run the same command without -VmDisplayName and -GuestName."
            }
        }
        # The old launcher may have run on Launcher\settings.psd1 since: a change there must not
        # be lost without a word. Defaults count as written, and the keys schema 2 added do not count.
        try { $different = @(Get-DeployDifferentKey -Left (Merge-PvmSetting -Settings $old) -Right (Merge-PvmSetting -Settings $values) -Ignore 'SchemaVersion', 'IsExample', 'VmDisplayName', 'GuestName') }
        catch { $different = @('sector values that are no whole numbers') }
        if ($different.Count -gt 0) {
            throw "Launcher\settings.psd1 and LauncherData\settings.psd1 differ in $($different -join ', '), so nothing was changed. The new launcher reads LauncherData\settings.psd1: make the two files agree, then run the same command again."
        }
    } else {
        try { $new = ConvertTo-PvmSchema2Text -Text $text -VmDisplayName $VmDisplayName -GuestName $GuestName }
        catch { throw "Launcher\settings.psd1 cannot be turned into schema 2, so nothing was changed: $($_.Exception.Message)." }
        $bytes = if ($new -match '[^\x00-\x7F]') {
            [byte[]]((New-Object System.Text.UTF8Encoding $true).GetPreamble() + (New-Object System.Text.UTF8Encoding $false).GetBytes($new))
        } else {
            [Text.Encoding]::ASCII.GetBytes($new)
        }
        # The new file is read back the way the launcher reads it, and must hold the old values
        # plus the new keys.
        $values = (Get-PvmDataFileHashtable -Text (ConvertFrom-PvmDataFileByte -Bytes $bytes)).SafeGetValue()
        $expected = @{}
        foreach ($key in $old.Keys) { $expected["$key"] = $old[$key] }
        $expected['SchemaVersion'] = 2
        if ($VmDisplayName) { $expected['VmDisplayName'] = $VmDisplayName }
        if ($GuestName) { $expected['GuestName'] = $GuestName }
        if (-not (Test-DeploySameValue -Left $values -Right $expected)) { throw 'The settings in schema 2 would not hold the values of Launcher\settings.psd1, so nothing was changed.' }
        $problems = @(Test-PvmSetting -Settings $values)
        if ($problems.Count -gt 0) {
            throw ("The settings in Launcher\settings.psd1, with the names given, do not pass the checks of schema 2, so nothing was changed. Fix them, then run the same command again:`n" +
                (($problems | ForEach-Object { "- $_" }) -join "`n"))
        }
    }
    $copies = Find-DeployLegacyCopy -Target $Target -Settings $values, $old
    $oldLog = Join-Path $Target 'Launcher\launcher.log'
    $log = Test-Path -LiteralPath $oldLog -PathType Leaf
    foreach ($copy in $copies.Move) { Write-Verbose "The migration moves $($copy.Relative) to LauncherData\backups\legacy." }
    foreach ($path in @(@($copies.Move | ForEach-Object { $_.Path }) + @(if ($log) { $oldLog }))) { Assert-DeployWriteAccess -Path $path }
    [pscustomobject]@{
        Bytes            = $bytes
        Values           = $values
        Copies           = $copies
        Log              = $log
        Descriptors      = @($copies.Move | Where-Object { $_.Kind -eq 'Descriptor' }).Count
        VirtualBoxCopies = @($copies.Move | Where-Object { $_.Kind -eq 'VirtualBox' }).Count
        KeptCopies       = $copies.Keep
    }
}

# Move what a migration moves into the stick folder $Target's LauncherData, which exists by then,
# as $Plan (Get-DeployMigrationPlan) says: a copy of Launcher\settings.psd1 to
# backups\legacy\Launcher unless one with its bytes is there, the log to logs, and each copy to
# the same path below backups\legacy. A name that is taken there gets a free one beside it
# (Get-DeployFreePath), so a log or a copy that the old launcher wrote after a migration stopped
# is kept too. Then every descriptor copy there is disarmed (Set-DeployDisarmedCopy), which
# repeats safely after a stop. Move-Item without -Force never replaces a file.
function Move-DeployLegacyData {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][pscustomobject]$Plan
    )
    $data = Join-Path $Target 'LauncherData'
    $legacy = Join-Path $data 'backups\legacy'
    if (-not $PSCmdlet.ShouldProcess($data, 'Move the legacy log and copies')) { return }
    $null = New-Item -ItemType Directory -Path (Join-Path $data 'logs'), (Join-Path $legacy 'Launcher') -Force
    $oldSettings = Join-Path $Target 'Launcher\settings.psd1'
    $hash = Get-DeployHash -Path $oldSettings
    if (@(Get-ChildItem -LiteralPath (Join-Path $legacy 'Launcher') -File | Where-Object { (Get-DeployHash -Path $_.FullName) -eq $hash }).Count -eq 0) {
        $null = Copy-DeployFile -Source $oldSettings -Destination (Get-DeployFreePath -Path (Join-Path $legacy 'Launcher\settings.psd1'))
    }
    if ($Plan.Log) { Move-Item -LiteralPath (Join-Path $Target 'Launcher\launcher.log') -Destination (Get-DeployFreePath -Path (Join-Path $data 'logs\launcher.log')) }
    foreach ($copy in $Plan.Copies.Move) {
        $destination = Get-DeployFreePath -Path (Join-Path $legacy $copy.Relative)
        $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force
        Move-Item -LiteralPath $copy.Path -Destination $destination
    }
    foreach ($copy in @(Get-ChildItem -LiteralPath $legacy -Recurse -File | Where-Object { $_.Name -like '*.vmdk.orig' -and $_.Length -lt $MaxDescriptorBytes })) {
        $null = Set-DeployDisarmedCopy -Path $copy.FullName
    }
}

# Deploy the launcher from the clone at $RepositoryPath to the stick folder $Target, as the header
# describes; -MigrateSettings, with the optional -VmDisplayName and -GuestName, moves schema 1
# settings to LauncherData first. Throws with the reason, before any change, when a check fails; a
# failure after the first change says what is left to do. Returns Version; Mode, which is Install
# (no Launcher folder), Update (settings in LauncherData), Migrate (schema 1 settings) or Resume (a
# migration that stopped after it created LauncherData); MovedCmdCount, the old launcher .cmd files
# moved into Launcher.previous; Plan, a migration's plan (Get-DeployMigrationPlan); and Applied,
# $false under -WhatIf.
function Invoke-PvmDeploy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Target,
        [switch]$MigrateSettings,
        [string]$VmDisplayName,
        [string]$GuestName
    )
    $launcher = Join-Path $Target 'Launcher'
    $staged = Join-Path $Target 'Launcher.new'
    $previous = Join-Path $Target 'Launcher.previous'
    $data = Join-Path $Target 'LauncherData'
    $dataStaged = Join-Path $Target 'LauncherData.new'
    $oldSettings = Join-Path $launcher 'settings.psd1'
    $cmdTarget = Join-Path $Target $CmdName
    $cmdStaged = Join-Path $Target "$CmdName.new"
    $leftovers = "Launcher.new and '$CmdName.new'"
    $sources = @($CodeFiles | ForEach-Object { Join-Path (Join-Path $RepositoryPath 'src') $_ })
    $cmdSource = Join-Path $RepositoryPath $CmdName

    # The clone, the parameters and the PC.
    foreach ($source in $sources + $cmdSource) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "The clone has no $(Split-Path $source -Leaf)." }
    }
    if (($VmDisplayName -or $GuestName) -and -not $MigrateSettings) {
        throw '-VmDisplayName and -GuestName go only with -MigrateSettings, which writes them into the new LauncherData\settings.psd1. Where that file is there already, set VmDisplayName and GuestName in it.'
    }
    Import-DeployModule -RepositoryPath $RepositoryPath
    $running = @(Get-DeployVmProcess)
    if ($running.Count -gt 0) { throw "A VM runs on this PC ($($running -join ', ')). Shut the guest down first." }

    # What an earlier deploy left.
    $hasLauncher = Test-Path -LiteralPath $launcher -PathType Container
    if (-not $hasLauncher -and (Test-Path -LiteralPath $previous)) {
        throw "The target has no Launcher folder, but Launcher.previous holds the launcher that an interrupted deploy replaced. Rename Launcher.previous back to Launcher, remove $leftovers if they are there, then deploy again."
    }
    if (Test-Path -LiteralPath $previous) {
        throw 'Launcher.previous holds the launcher that the last deploy replaced. Remove it or move it away first.'
    }
    if (Test-Path -LiteralPath $dataStaged) {
        throw "LauncherData.new is left from a migration whose staging did not finish, and nothing the launcher uses was changed. Remove LauncherData.new, and $leftovers if they are there, then run the same command again."
    }

    # Where the settings are decides what the deploy does.
    $hasOldSettings = Test-Path -LiteralPath $oldSettings -PathType Leaf
    if (-not $hasLauncher) {
        if ($MigrateSettings) { throw 'The target has no Launcher folder, so there are no settings to migrate. Deploy without -MigrateSettings.' }
        $mode = 'Install'
    } elseif ($hasOldSettings) {
        try { $oldValues = Import-PvmDataFile -Path $oldSettings -Legacy }
        catch { throw "Launcher\settings.psd1 cannot be read: $($_.Exception.Message)." }
        if (@($oldValues.Keys | Where-Object { "$_" -eq 'SchemaVersion' }).Count -gt 0) {
            throw 'Launcher\settings.psd1 holds schema 2 settings, but the launcher reads them from LauncherData\settings.psd1. Move the file there, then deploy again.'
        }
        if (-not $MigrateSettings) {
            throw 'The stick keeps its settings in Launcher\settings.psd1, as the launcher before LauncherData did. Deploy once with -MigrateSettings, which moves them to LauncherData; add -WhatIf first to see what it would do.'
        }
        $mode = if (Test-Path -LiteralPath $data -PathType Container) { 'Resume' } else { 'Migrate' }
    } else {
        if ($MigrateSettings) { throw 'The settings are in LauncherData already, so there is nothing to migrate. Deploy without -MigrateSettings.' }
        $mode = 'Update'
    }
    $plan = $null
    if ($mode -eq 'Install' -or $mode -eq 'Update') {
        try { $null = Import-PvmSetting -Path (Join-Path $data 'settings.psd1') }
        catch {
            $stop = Get-PvmStopMessage -ErrorRecord $_
            if ($null -eq $stop) { throw }
            throw "The new launcher reads LauncherData\settings.psd1, which must pass its checks first, so nothing was changed. $stop"
        }
    } else {
        $plan = Get-DeployMigrationPlan -Target $Target -VmDisplayName $VmDisplayName -GuestName $GuestName -Resume:($mode -eq 'Resume')
    }

    # The .cmd files are checked now, so that nothing they hold can stop the last step after the swap.
    try { $oldCmds = @(Find-DeployLauncherCmd -Folder $Target) }
    catch { throw "A .cmd file at the target cannot be read, so the old launcher .cmd cannot be found: $($_.Exception.Message)" }
    if ($mode -eq 'Install' -and $oldCmds.Count -gt 0) {
        throw 'A launcher .cmd is at the target, but there is no Launcher folder to keep it in. Move the .cmd files that start a launcher away first.'
    }
    if ((Test-Path -LiteralPath $cmdTarget) -and @($oldCmds | Where-Object { $_.Name -eq $CmdName }).Count -eq 0) {
        throw "'$CmdName' at the target does not start the launcher. Move it away first."
    }
    foreach ($old in $oldCmds) {
        if (Test-Path -LiteralPath (Join-Path $launcher $old.Name)) {
            throw 'Launcher holds a file with the name of an old launcher .cmd, which would block moving the .cmd into Launcher.previous. Move that file out of Launcher first.'
        }
    }

    # A resumed migration uses what its first run staged, when it is what this run would stage.
    $version = Get-DeployVersion -RepositoryPath $RepositoryPath
    $hashes = @{}
    foreach ($source in $sources) { $hashes[$source] = Get-DeployHash -Path $source }
    $sums = (@($sources | ForEach-Object { '{0}  {1}' -f $hashes[$_], (Split-Path $_ -Leaf) }) -join "`n") + "`n"
    $reuseCode = $false
    $reuseCmd = $false
    if (Test-Path -LiteralPath $staged) {
        $reuseCode = $mode -eq 'Resume' -and (Test-Path -LiteralPath $staged -PathType Container) -and
        (Test-DeployStagedCode -Folder $staged -Sources $sources -Sums $sums -Version $version)
        if (-not $reuseCode) { throw 'Launcher.new is left from an earlier deploy and holds only copies. Remove it first.' }
    }
    if (Test-Path -LiteralPath $cmdStaged) {
        $reuseCmd = $mode -eq 'Resume' -and (Test-Path -LiteralPath $cmdStaged -PathType Leaf) -and
        (Get-DeployHash -Path $cmdStaged) -eq (Get-DeployHash -Path $cmdSource)
        if (-not $reuseCmd) { throw "'$CmdName.new' is left from an earlier deploy and holds only copies. Remove it first." }
    }

    $result = [pscustomobject]@{ Version = $version; Mode = $mode; MovedCmdCount = $oldCmds.Count; Plan = $plan; Applied = $false }
    # The target is not named, since the stick's folder names can be private.
    if (-not $PSCmdlet.ShouldProcess('the -Target folder', "Deploy the launcher $version")) { return $result }
    # That was the one question -Confirm asks: the steps below run as one unit, without asking again.
    $ConfirmPreference = 'None'

    # Everything is staged and checked first, so a failed copy changes nothing the launcher uses.
    try {
        if (-not $reuseCode) {
            $null = New-Item -ItemType Directory -Path $staged
            foreach ($source in $sources) { $null = Copy-DeployFile -Source $source -Destination (Join-Path $staged (Split-Path $source -Leaf)) }
            [IO.File]::WriteAllText((Join-Path $staged 'SHA256SUMS'), $sums, [Text.Encoding]::ASCII)
            [IO.File]::WriteAllText((Join-Path $staged 'VERSION'), "$version`n", [Text.Encoding]::ASCII)
        }
        if (-not $reuseCmd) { $null = Copy-DeployFile -Source $cmdSource -Destination $cmdStaged }
        if ($mode -eq 'Migrate') {
            $null = New-Item -ItemType Directory -Path (Join-Path $dataStaged 'logs'), (Join-Path $dataStaged 'backups\legacy\Launcher')
            $newSettings = Join-Path $dataStaged 'settings.psd1'
            [IO.File]::WriteAllBytes($newSettings, $plan.Bytes)
            if (-not (Test-DeploySameValue -Left (Import-PvmDataFile -Path $newSettings) -Right $plan.Values)) { throw 'The new settings.psd1 did not read back as written.' }
            $null = Copy-DeployFile -Source $oldSettings -Destination (Join-Path $dataStaged 'backups\legacy\Launcher\settings.psd1')
        }
    } catch {
        $remove = if ($mode -eq 'Migrate') { "LauncherData.new, $leftovers" } else { $leftovers }
        throw "Staging failed and nothing the launcher uses was changed. Remove $remove, then run the same command again: $($_.Exception.Message)"
    }

    # The data first: until the code swap, the old launcher in Launcher keeps working with
    # Launcher\settings.psd1, which stays there.
    if ($mode -eq 'Migrate') {
        try { Rename-DeployItem -Path $dataStaged -NewName 'LauncherData' }
        catch { throw "LauncherData.new could not become LauncherData, and nothing the launcher uses was changed. Remove LauncherData.new, $leftovers, then run the same command again: $($_.Exception.Message)" }
    }
    if ($plan) {
        try { Move-DeployLegacyData -Target $Target -Plan $plan }
        catch { throw "The migration stopped part way, but the launcher in Launcher still works with Launcher\settings.psd1. Run the same command again to finish it: $($_.Exception.Message)" }
    }

    if ($mode -eq 'Install') {
        try {
            Rename-DeployItem -Path $staged -NewName 'Launcher'
            Rename-DeployItem -Path $cmdStaged -NewName $CmdName
        } catch {
            throw "The launcher could not be put in place. Rename Launcher.new to Launcher and '$CmdName.new' to '$CmdName' if they are still there. $($_.Exception.Message)"
        }
        $result.Applied = $true
        return $result
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
            throw "Launcher is missing: Launcher.previous holds the launcher that was in use. Rename Launcher.previous back to Launcher, remove $leftovers, then deploy again. $reason"
        }
        throw "Launcher.new could not take the place of Launcher, so Launcher is back as it was. Remove $leftovers, then deploy again. $reason"
    }
    try {
        foreach ($old in $oldCmds) { Move-Item -LiteralPath $old.FullName -Destination (Join-Path $previous $old.Name) }
        Rename-DeployItem -Path $cmdStaged -NewName $CmdName
    } catch {
        throw "The new launcher is in Launcher, but its .cmd is not in place yet. Move the old launcher .cmd files at the stick's root into Launcher.previous, then rename '$CmdName.new' to '$CmdName'. $($_.Exception.Message)"
    }
    $result.Applied = $true
    $result
}

# Return the error message $Message with every quoted path below the full path $Target, or $Target
# itself, replaced by a placeholder, since the stick's folder and file names can be private. The
# path ends at the quote that closes it: one followed by a blank, a punctuation mark or the end, so
# an apostrophe in a name does not end it early. Text outside quotes stays as it is.
function Hide-DeployTargetPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][string]$Target
    )
    $base = [regex]::Escape($Target.TrimEnd('\', '/'))
    $pattern = "(?<=['""])$base(?:[\\/][^\r\n]*?)?(?=['""](?:[\s.,;:!?)]|$))"
    [regex]::Replace($Message, $pattern, '<a path below -Target, which -Verbose shows>', 'IgnoreCase')
}

# Return the report lines for the deploy result $Result (Invoke-PvmDeploy): what was deployed, or
# would be under -WhatIf, and what a migration moved. They name no file from the stick.
function Format-DeployReport {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][pscustomobject]$Result)
    $done = $Result.Applied
    $moved = if ($done) { 'moved' } else { 'to move' }
    "$(if ($done) { 'deployed' } else { 'would deploy' }) $($Result.Version) ($($Result.Mode))."
    $plan = $Result.Plan
    if ($plan) {
        if ($Result.Mode -eq 'Resume') {
            "settings: LauncherData\settings.psd1 $(if ($done) { 'was kept' } else { 'would be kept' }) as it is, with a copy of the old file in LauncherData\backups\legacy\Launcher."
        } else {
            "settings: LauncherData\settings.psd1 $(if ($done) { 'holds' } else { 'would hold' }) them in schema 2, with a copy of the old file in LauncherData\backups\legacy\Launcher."
        }
        "log $moved to LauncherData\logs: $(if ($plan.Log) { 1 } else { 0 })."
        "descriptor copies $moved to LauncherData\backups\legacy and disarmed: $($plan.Descriptors)."
        "VirtualBox copies $moved to LauncherData\backups\legacy: $($plan.VirtualBoxCopies)."
        "other copies left beside the VM files: $($plan.KeptCopies)."
    }
    if ($Result.Mode -ne 'Install') { "old launcher .cmd files $moved into Launcher.previous: $($Result.MovedCmdCount)." }
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $Target) { throw 'Give -Target, the folder on the stick that holds the Launcher and LauncherData folders.' }
        # A full path, so that every path an error quotes starts with it (Hide-DeployTargetPath).
        $Target = Convert-Path -LiteralPath $Target
        # -WhatIf and -Confirm go to Invoke-PvmDeploy alone: left in effect for the whole script,
        # they also reach the modules PowerShell loads on the way, which then skip or ask about
        # parts of their setup. For the same reason CimCmdlets, which the VM check needs, is loaded
        # before the deploy.
        $whatIf = [bool]$WhatIfPreference
        $confirm = $PSBoundParameters.ContainsKey('Confirm') -and [bool]$PSBoundParameters['Confirm']
        $WhatIfPreference = $false
        $ConfirmPreference = 'High'
        Import-Module -Name CimCmdlets
        $deploy = @{ RepositoryPath = (Split-Path $PSScriptRoot -Parent); Target = $Target; MigrateSettings = $MigrateSettings; VmDisplayName = $VmDisplayName; GuestName = $GuestName }
        $done = Invoke-PvmDeploy @deploy -WhatIf:$whatIf -Confirm:$confirm
        foreach ($line in Format-DeployReport -Result $done) { Write-Output "Deploy-PortableVM: $line" }
        exit 0
    } catch {
        $message = $_.Exception.Message
        Write-Verbose $message
        # The stick's folder and file names can be private, so a path below -Target that an error
        # quotes is left out; -Verbose above shows it.
        if ($Target) { $message = Hide-DeployTargetPath -Message $message -Target $Target }
        Write-Output "Deploy-PortableVM: $message"
        exit 1
    }
}
