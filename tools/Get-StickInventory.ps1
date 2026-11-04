# -------------------------------------------------------
#                   GET STICK INVENTORY
# -------------------------------------------------------
#
# Reads a stick and the VM files on it and reports what the next phases of the redesign rely on,
# without changing anything. -Root is the folder on the stick's Data partition that holds the
# Launcher folder, for example X:\; -SettingsPath defaults to Launcher\settings.psd1 there. Run it
# in Windows PowerShell 5.1, elevated if Get-Disk needs it on this PC:
#   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Get-StickInventory.ps1 -Root X:\
# Each line holds a check and yes, no or unknown, and never a value read from the stick or the
# PC, so the output can go into a pull request as it is. -Verbose adds why a check is unknown,
# which can name a path. Exits 0 after the report, 2 when it cannot run.

[CmdletBinding()]
param(
    [string]$Root,
    [string]$SettingsPath
)

$ErrorActionPreference = 'Stop'

# Windows file systems; a partition in the VM's range with one of these is mounted by Windows.
$WindowsFileSystems = @('NTFS', 'FAT', 'FAT32', 'exFAT', 'ReFS')
# Larger .vmdk files hold disk data, not a descriptor, and are not read.
$MaxDescriptorBytes = 1MB

# Return the partition with the drive letter $DriveLetter.
function Get-InventoryPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DriveLetter)
    Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
}

# Return the disk with the number $Number.
function Get-InventoryDisk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$Number)
    Get-Disk -Number $Number -ErrorAction Stop
}

# Return the partitions of the disk with the number $DiskNumber.
function Get-InventoryDiskPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$DiskNumber)
    Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop
}

# Return the volume on the partition $Partition, or nothing when Windows has none on it. Any other
# error is thrown, so that the check that asked answers unknown.
function Get-InventoryVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Partition)
    try { $Partition | Get-Volume -ErrorAction Stop }
    catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
}

# Return the value $Name of the registry key $Path, or $null when the key or the value is missing.
function Get-InventoryRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    $key = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $key -and $null -ne $key.PSObject.Properties[$Name]) { $key.PSObject.Properties[$Name].Value } else { $null }
}

# Return the check $Name with its Answer: $true or $false as $Test returns it, or $null, which
# reports as unknown, when $Test returns nothing or throws.
function Get-InventoryCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Test
    )
    $answer = $null
    try {
        $value = & $Test
        if ($null -ne $value) { $answer = [bool]$value }
    } catch {
        Write-Verbose "${Name}: $($_.Exception.Message)"
    }
    [pscustomobject]@{ Name = $Name; Answer = $answer }
}

# Return the report line of the check $Check: its name, then yes, no or unknown.
function Format-InventoryLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Check)
    $word = if ($null -eq $Check.Answer) { 'unknown' } elseif ($Check.Answer) { 'yes' } else { 'no' }
    "Get-StickInventory: $($Check.Name): $word"
}

# Return the file $Path as Found, whether it exists ($null without a path), and Text, its text,
# or $null when it is missing or cannot be read.
function Read-InventoryFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)
    $found = $null
    $text = $null
    if ($Path) {
        $found = Test-Path -LiteralPath $Path -PathType Leaf
        if ($found) {
            try { $text = [IO.File]::ReadAllText($Path) } catch { Write-Verbose "Cannot read ${Path}: $($_.Exception.Message)" }
        }
    }
    [pscustomobject]@{ Found = $found; Text = $text }
}

# Return the XML file $Path as Found, as Read-InventoryFile does, Readable, and Document: the
# document read with DTDs refused, or $null when the file is missing, unreadable or no XML.
function Read-InventoryXml {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)
    $file = Read-InventoryFile -Path $Path
    $document = $null
    if ($null -ne $file.Text) {
        $readerSettings = New-Object System.Xml.XmlReaderSettings
        $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        try {
            $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($file.Text), $readerSettings)
            try {
                $document = New-Object System.Xml.XmlDocument
                $document.Load($reader)
            } finally {
                $reader.Close()
            }
        } catch {
            Write-Verbose "Cannot parse ${Path}: $($_.Exception.Message)"
            $document = $null
        }
    }
    [pscustomobject]@{ Found = $file.Found; Readable = ($null -ne $file.Text); Document = $document }
}

# Return the settings in the .vmx text $Text as a hashtable with lowercase keys and unquoted
# values. A key that appears twice keeps its last value, as VMware reads it.
function ConvertFrom-InventoryVmx {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyString()][string]$Text)
    $values = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*"(.*)"\s*$') { $values[$Matches[1].ToLowerInvariant()] = $Matches[2] }
    }
    $values
}

# Return whether $Path and $Other name the same file, compared without case.
function Test-InventorySamePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Other
    )
    [string]::Equals([IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($Other), [StringComparison]::OrdinalIgnoreCase)
}

# Return the checks of the descriptor $Path, named after $Area: whether it is there, whether a FLAT
# extent names a PhysicalDrive, whether its createType is fullDevice, and whether the folder holds
# another descriptor that names a PhysicalDrive or a -pt.vmdk partition-table copy.
function Get-InventoryDescriptorCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [string]$Path
    )
    $file = Read-InventoryFile -Path $Path
    $text = $file.Text
    $folder = if ($Path) { Split-Path $Path } else { $null }
    Get-InventoryCheck -Name "$Area descriptor found" -Test { $file.Found }
    Get-InventoryCheck -Name "$Area descriptor names a PhysicalDrive" -Test {
        if ($null -ne $text) { $text -match '(?im)^\s*(RW|RDONLY|NOACCESS)\s+\d+\s+FLAT\s+"\\\\\.\\PhysicalDrive\d+"' }
    }
    Get-InventoryCheck -Name "$Area descriptor has createType fullDevice" -Test {
        if ($null -ne $text) { $text -match '(?im)^\s*createType\s*=\s*"fullDevice"' }
    }
    Get-InventoryCheck -Name "$Area folder has another descriptor that names a PhysicalDrive" -Test {
        if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
            @(Get-ChildItem -LiteralPath $folder -Filter '*.vmdk' -File | Where-Object {
                    $_.Length -lt $MaxDescriptorBytes -and -not (Test-InventorySamePath -Path $_.FullName -Other $Path) -and
                    ([IO.File]::ReadAllText($_.FullName) -match 'PhysicalDrive')
                }).Count -gt 0
        }
    }
    Get-InventoryCheck -Name "$Area folder has a -pt.vmdk file" -Test {
        if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) { @(Get-ChildItem -LiteralPath $folder -Filter '*-pt.vmdk' -File).Count -gt 0 }
    }
}

# Return the checks of the stick that holds $Root against $Settings: identity and layout as the
# launcher checks them, and whether Windows mounts a partition in the VM's range before Data.
function Get-InventoryStickCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$Settings
    )
    $partition = $null
    $disk = $null
    $diskFound = $null
    $before = $null
    try {
        $partition = Get-InventoryPartition -DriveLetter (Split-Path -Qualifier $Root).TrimEnd(':')
    } catch {
        Write-Verbose "stick partition: $($_.Exception.Message)"
        # No partition has the root's drive letter; any other error leaves it unknown.
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $diskFound = $false }
    }
    if ($partition) {
        try {
            $disk = Get-InventoryDisk -Number $partition.DiskNumber
            $diskFound = $true
        } catch {
            Write-Verbose "stick disk: $($_.Exception.Message)"
        }
    }
    if ($disk -and $Settings) {
        try {
            $before = @(Get-InventoryDiskPartition -DiskNumber $disk.Number | Where-Object { [int64]($_.Offset / 512) -lt $Settings['DataPartitionStart'] })
        } catch {
            Write-Verbose "stick partitions: $($_.Exception.Message)"
        }
    }
    $known = $null -ne $disk -and $null -ne $Settings
    Get-InventoryCheck -Name 'stick disk found from the drive letter' -Test { $diskFound }
    Get-InventoryCheck -Name 'stick is MBR' -Test { if ($disk) { $disk.PartitionStyle -eq 'MBR' } }
    Get-InventoryCheck -Name 'stick signature matches StickMbrSignature' -Test {
        if ($known) { ('{0:X8}' -f [uint32]$disk.Signature) -eq $Settings['StickMbrSignature'] }
    }
    Get-InventoryCheck -Name 'stick has 512-byte sectors' -Test { if ($disk) { $disk.LogicalSectorSize -eq 512 } }
    Get-InventoryCheck -Name 'stick size matches StickSectors' -Test { if ($known) { [int64]($disk.Size / 512) -eq $Settings['StickSectors'] } }
    Get-InventoryCheck -Name 'Data partition starts at DataPartitionStart' -Test {
        if ($known) { [int64]($partition.Offset / 512) -eq $Settings['DataPartitionStart'] }
    }
    Get-InventoryCheck -Name 'Data partition ends at VmSectors' -Test {
        if ($known) { [int64](($partition.Offset + $partition.Size) / 512) -eq $Settings['VmSectors'] }
    }
    Get-InventoryCheck -Name "stick is not this PC's boot or system disk" -Test { if ($disk) { -not ($disk.IsBoot -or $disk.IsSystem) } }
    Get-InventoryCheck -Name 'a partition before Data has a drive letter' -Test {
        if ($null -ne $before) { @($before | Where-Object { [int][char]$_.DriveLetter -gt 0 }).Count -gt 0 }
    }
    Get-InventoryCheck -Name 'a partition before Data has a Windows file system' -Test {
        if ($null -ne $before) {
            @($before | Where-Object { $volume = Get-InventoryVolume -Partition $_; $volume -and $WindowsFileSystems -contains $volume.FileSystem }).Count -gt 0
        }
    }
}

# Return the checks of the VMware files that $Settings name below $Root: the .vmx keys the next
# phases require, the saved state, whether a disk entry that is switched on attaches the
# descriptor, and lock folders.
function Get-InventoryVMwareCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$Settings
    )
    $vmxPath = if ($Settings -and $Settings['VMwareVmx']) { Join-Path $Root $Settings['VMwareVmx'] } else { $null }
    $diskPath = if ($Settings -and $Settings['VMwareDisk']) { Join-Path $Root $Settings['VMwareDisk'] } else { $null }
    $vmxFile = Read-InventoryFile -Path $vmxPath
    $vmx = if ($null -ne $vmxFile.Text) { ConvertFrom-InventoryVmx -Text $vmxFile.Text } else { $null }
    Get-InventoryCheck -Name 'VMware .vmx found' -Test { $vmxFile.Found }
    Get-InventoryCheck -Name 'VMware .vmx has a suspended state' -Test { if ($vmx) { [bool]$vmx['checkpoint.vmstate'] } }
    Get-InventoryCheck -Name 'VMware .vmx has suspend.disabled = "TRUE"' -Test { if ($vmx) { $vmx['suspend.disabled'] -eq 'TRUE' } }
    Get-InventoryCheck -Name 'VMware .vmx has uuid.action = "keep"' -Test { if ($vmx) { $vmx['uuid.action'] -eq 'keep' } }
    Get-InventoryCheck -Name 'VMware .vmx has mainMem.useNamedFile = "FALSE"' -Test { if ($vmx) { $vmx['mainmem.usenamedfile'] -eq 'FALSE' } }
    Get-InventoryCheck -Name 'VMware .vmx attaches the VMwareDisk descriptor' -Test {
        if ($vmx -and $diskPath) {
            # Unknown when the entry that names the descriptor has no present key.
            $answer = $false
            foreach ($key in @($vmx.Keys)) {
                if ($key -notmatch '^((ide|scsi|sata|nvme)\d+):\d+\.filename$') { continue }
                $controller = $Matches[1]
                $file = $vmx[$key]
                if (-not [IO.Path]::IsPathRooted($file)) { $file = Join-Path (Split-Path $vmxPath) $file }
                if (-not (Test-InventorySamePath -Path $file -Other $diskPath)) { continue }
                # A disk entry that is switched off keeps its fileName, and so does one on a
                # controller that is switched off.
                if ($vmx["$controller.present"] -eq 'FALSE') { continue }
                $present = $vmx[$key -replace '\.filename$', '.present']
                if ($present -eq 'TRUE') { return $true }
                if ($null -eq $present) { $answer = $null }
            }
            $answer
        }
    }
    Get-InventoryCheck -Name 'VMware folder has a .lck lock folder' -Test {
        if ($vmxPath -and (Test-Path -LiteralPath (Split-Path $vmxPath) -PathType Container)) {
            @(Get-ChildItem -LiteralPath (Split-Path $vmxPath) -Filter '*.lck' -Directory).Count -gt 0
        }
    }
    Get-InventoryDescriptorCheck -Area 'VMware' -Path $diskPath
    Get-InventoryCheck -Name 'VMware descriptor has a .orig copy' -Test { if ($diskPath) { Test-Path -LiteralPath "$diskPath.orig" } }
}

# Return the checks of the VirtualBox files that $Settings name below $Root: the saved state, the
# attached descriptor and its controller's host I/O cache and bandwidth group, drive-letter paths,
# and the VM's entry in VirtualBox.xml.
function Get-InventoryVirtualBoxCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [hashtable]$Settings
    )
    $vboxPath = if ($Settings -and $Settings['VirtualBoxVbox']) { Join-Path $Root $Settings['VirtualBoxVbox'] } else { $null }
    $diskPath = if ($Settings -and $Settings['VirtualBoxDisk']) { Join-Path $Root $Settings['VirtualBoxDisk'] } else { $null }
    $homePath = if ($Settings -and $Settings['VirtualBoxHome']) { Join-Path $Root $Settings['VirtualBoxHome'] } else { $null }
    $registryPath = if ($homePath) { Join-Path $homePath 'VirtualBox.xml' } else { $null }
    $vbox = Read-InventoryXml -Path $vboxPath
    $registry = Read-InventoryXml -Path $registryPath

    # The uuid of the configured descriptor, from a HardDisk entry in the .vbox or in the global
    # media registry of VirtualBox.xml, and the AttachedDevice of the VM's current state, outside
    # any snapshot, that uses it. A location that is no file path, such as an iSCSI target, is
    # skipped.
    $attached = $null
    $lookupFailed = $false
    if ($vbox.Document -and $diskPath) {
        try {
            $registries = @(@{ Document = $vbox.Document; Folder = (Split-Path $vboxPath) }, @{ Document = $registry.Document; Folder = $homePath })
            $uuids = @(foreach ($source in $registries) {
                    if (-not $source.Document) { continue }
                    foreach ($hardDisk in $source.Document.SelectNodes("//*[local-name()='HardDisk']")) {
                        $location = $hardDisk.GetAttribute('location')
                        if (-not $location -or $location.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { continue }
                        if (-not [IO.Path]::IsPathRooted($location)) { $location = Join-Path $source.Folder $location }
                        if (Test-InventorySamePath -Path $location -Other $diskPath) { $hardDisk.GetAttribute('uuid') }
                    }
                })
            $attached = @($vbox.Document.SelectNodes("//*[local-name()='AttachedDevice'][not(ancestor::*[local-name()='Snapshot'])]") | Where-Object {
                    @($_.ChildNodes | Where-Object { $_.LocalName -eq 'Image' -and $uuids -contains $_.GetAttribute('uuid') }).Count -gt 0
                }) | Select-Object -First 1
        } catch {
            Write-Verbose "VirtualBox attachment: $($_.Exception.Message)"
            $lookupFailed = $true
        }
    }

    Get-InventoryCheck -Name 'VirtualBox .vbox found' -Test { $vbox.Found }
    Get-InventoryCheck -Name 'VirtualBox .vbox parses as XML' -Test { if ($vbox.Readable) { $null -ne $vbox.Document } }
    Get-InventoryCheck -Name 'VirtualBox .vbox has a saved state' -Test {
        if ($vbox.Document) { [bool]@($vbox.Document.SelectNodes("//*[local-name()='Machine']") | Where-Object { $_.GetAttribute('stateFile') }).Count }
    }
    Get-InventoryCheck -Name 'VirtualBox .vbox attaches the VirtualBoxDisk descriptor' -Test {
        if ($vbox.Document -and $diskPath -and -not $lookupFailed) { $null -ne $attached }
    }
    Get-InventoryCheck -Name "VirtualBox host I/O cache is on for the descriptor's controller" -Test {
        if ($attached) {
            $cache = $attached.ParentNode.GetAttribute('useHostIOCache')
            if ($cache) { $cache -eq 'true' }
        }
    }
    Get-InventoryCheck -Name 'VirtualBox descriptor has a bandwidth group' -Test { if ($attached) { [bool]$attached.GetAttribute('bandwidthGroup') } }
    Get-InventoryCheck -Name 'VirtualBox .vbox holds paths with a drive letter' -Test {
        if ($vbox.Document) { @($vbox.Document.SelectNodes('//@*') | Where-Object { $_.Value -match '^[A-Za-z]:[\\/]' }).Count -gt 0 }
    }
    Get-InventoryCheck -Name 'VirtualBox.xml found' -Test { $registry.Found }
    Get-InventoryCheck -Name 'VirtualBox.xml parses as XML' -Test { if ($registry.Readable) { $null -ne $registry.Document } }
    $entry = $null
    if ($registry.Document -and $Settings -and $Settings['VirtualBoxVmUuid']) {
        $entry = @($registry.Document.SelectNodes("//*[local-name()='MachineEntry']") | Where-Object {
                $_.GetAttribute('uuid').Trim('{', '}') -eq $Settings['VirtualBoxVmUuid']
            }) | Select-Object -First 1
    }
    Get-InventoryCheck -Name 'VirtualBox.xml lists the VM' -Test { if ($registry.Document -and $Settings -and $Settings['VirtualBoxVmUuid']) { $null -ne $entry } }
    Get-InventoryCheck -Name "VirtualBox.xml lists the VM's .vbox with a drive letter" -Test {
        if ($entry) { $entry.GetAttribute('src') -match '^[A-Za-z]:' }
    }
    Get-InventoryDescriptorCheck -Area 'VirtualBox' -Path $diskPath
    Get-InventoryCheck -Name 'VirtualBox files have .launcher-backup copies' -Test {
        if ($vboxPath -and $registryPath) { (Test-Path -LiteralPath "$vboxPath.launcher-backup") -or (Test-Path -LiteralPath "$registryPath.launcher-backup") }
    }
}

# Return the checks of this PC: which of the two hypervisors the launcher finds installed, read
# from the same registry keys and files as the launcher reads them.
function Get-InventoryHostCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    Get-InventoryCheck -Name 'VMware Workstation installed' -Test {
        $found = $false
        foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation', 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation') {
            $dir = Get-InventoryRegistryValue -Path $key -Name 'InstallPath'
            if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'vmware.exe'))) { $found = $true }
        }
        $found
    }
    Get-InventoryCheck -Name 'VirtualBox installed' -Test {
        $dir = Get-InventoryRegistryValue -Path 'HKLM:\SOFTWARE\Oracle\VirtualBox' -Name 'InstallDir'
        [bool]($dir -and (Test-Path -LiteralPath (Join-Path $dir 'VBoxManage.exe')))
    }
}

# Return every check of the stick folder $Root, read with the settings file $SettingsPath.
function Get-StickInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$SettingsPath
    )
    $settings = $null
    try { $settings = Import-PowerShellDataFile -LiteralPath $SettingsPath -ErrorAction Stop } catch { Write-Verbose "settings: $($_.Exception.Message)" }
    Get-InventoryCheck -Name 'settings file read' -Test { $null -ne $settings }
    Get-InventoryStickCheck -Root $Root -Settings $settings
    Get-InventoryVMwareCheck -Root $Root -Settings $settings
    Get-InventoryVirtualBoxCheck -Root $Root -Settings $settings
    Get-InventoryHostCheck
}

# Run only when started as a script, not when a test dot-sources this file for its functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $Root) { throw 'Give -Root, the folder on the stick that holds the Launcher folder.' }
        if (-not $SettingsPath) { $SettingsPath = Join-Path $Root 'Launcher\settings.psd1' }
        Get-StickInventory -Root $Root -SettingsPath $SettingsPath | ForEach-Object { Format-InventoryLine -Check $_ }
        exit 0
    } catch {
        Write-Verbose $_.Exception.Message
        Write-Output "Get-StickInventory: the inventory could not run ($($_.Exception.GetType().Name)); run it with -Verbose for the reason."
        exit 2
    }
}
