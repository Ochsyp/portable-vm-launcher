# Characterisation tests of src\PortableVM.psm1: what the launcher decides, logs and writes, as it
# did before the redesign, apart from the changes CHANGELOG.md lists. The stick and the PC are
# synthetic: disks and partitions are PSCustomObjects, the stick's files live in TestDrive, with
# the settings and the log in LauncherData, every adapter is mocked, and $env:PVM_TEST makes an
# unmocked one throw. A test whose name says "known issue" pins behaviour that the phase it names
# changes. tests\Settings.Tests.ps1 tests the settings checks themselves.

BeforeAll {
    $script:previousTestFlag = $env:PVM_TEST
    $env:PVM_TEST = '1'
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force
    $script:utf8 = New-Object System.Text.UTF8Encoding $false
    $script:uuid = '5ca1ab1e-0000-4000-8000-000000000001'
    $script:onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    # These tests pin the launcher's decisions on Windows, so on another system the launcher takes
    # its Windows rules here too; the tests of a rule that differs mock the host either way.
    if (-not $script:onWindows) { Mock -ModuleName PortableVM Test-PvmWindowsHost { $true } }
    # The program names, without .exe, that the launcher's process checks ask for.
    $script:vmwareNames = 'vmware-vmx'
    $script:virtualBoxVmNames = 'VirtualBoxVM,VBoxHeadless'
    $script:virtualBoxOpenNames = 'VirtualBox,VirtualBoxVM,VBoxHeadless'

    # Return the system's ANSI code page, read from the registry, in which the launcher writes its
    # log: a test of the log checks the launcher's bytes against it, not against the launcher's
    # own choice of encoding. Outside Windows the log is UTF-8.
    function Get-TestAnsiEncoding {
        if (-not $script:onWindows) { return (New-Object System.Text.UTF8Encoding $false) }
        [Text.Encoding]::GetEncoding([int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage').ACP)
    }

    # Create and return the mutex named $Name with a security descriptor that denies this user
    # every right to it, as when an elevated run holds the lock. .NET Framework and .NET take the
    # descriptor in different calls.
    function New-TestDeniedMutex {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that makes a mutex of this process only.')]
        param([string]$Name)
        $security = [System.Security.AccessControl.MutexSecurity]::new()
        $security.AddAccessRule([System.Security.AccessControl.MutexAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Deny))
        $created = $false
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            $mutex = [System.Threading.Mutex]::new($false, $Name, [ref]$created, $security)
        } else {
            $acl = [Type]::GetType('System.Threading.MutexAcl, System.Threading.AccessControl', $true)
            $mutex = $acl::Create($false, $Name, [ref]$created, $security)
        }
        if (-not $created) { $mutex.Dispose(); throw "The mutex $Name existed already." }
        $mutex
    }

    # Write $Text to the file $Path as UTF-8 without a BOM, creating its folder.
    function Write-TestFile {
        param([string]$Path, [string]$Text)
        $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
        [IO.File]::WriteAllText($Path, $Text, $script:utf8)
    }

    # Return the stick's disk as the launcher reads it: disk 3, MBR, signature 5CA1AB1E and
    # 4000000 sectors of 512 bytes, with the properties in $Change replaced.
    function Get-TestDisk {
        param([hashtable]$Change = @{})
        $disk = [ordered]@{
            Number = 3; PartitionStyle = 'MBR'; Signature = [uint32]0x5CA1AB1E; LogicalSectorSize = 512
            Size = [uint64]4000000 * 512; IsBoot = $false; IsSystem = $false
        }
        foreach ($key in $Change.Keys) { $disk[$key] = $Change[$key] }
        [pscustomobject]$disk
    }

    # Return the Data partition the launcher runs from: sectors 2500000 to 3900000 of disk 3,
    # with the properties in $Change replaced.
    function Get-TestPartition {
        param([hashtable]$Change = @{})
        $partition = [ordered]@{ DiskNumber = 3; Offset = [uint64]2500000 * 512; Size = [uint64]1400000 * 512 }
        foreach ($key in $Change.Keys) { $partition[$key] = $Change[$key] }
        [pscustomobject]$partition
    }

    # Return the schema 2 settings of the synthetic stick, with the values in $Change replaced; a
    # $null in $Change leaves that key out.
    function Get-TestSettingTable {
        param([hashtable]$Change = @{})
        $settings = @{
            SchemaVersion = 2; Hypervisor = 'Auto'; VMwareView = 'Window'; HideDataPartition = $false
            StickMbrSignature = '5CA1AB1E'; StickSectors = 4000000; VmSectors = 3900000; DataPartitionStart = 2500000
            VirtualBoxVmUuid = $script:uuid; VirtualBoxHome = 'VirtualBox'
            VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'; VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'
            VMwareVmx = 'VMware\Test VM.vmx'; VMwareDisk = 'VMware\stick.vmdk'
        }
        foreach ($key in $Change.Keys) {
            if ($null -eq $Change[$key]) { $settings.Remove($key) } else { $settings[$key] = $Change[$key] }
        }
        $settings
    }

    # Return the hashtable $Settings as the text of a PowerShell data file, a key per line in
    # sorted order, with CRLF line endings.
    function ConvertTo-TestSettingsText {
        param([hashtable]$Settings)
        $lines = foreach ($key in ($Settings.Keys | Sort-Object)) {
            $value = $Settings[$key]
            $literal = if ($value -is [bool]) { "`$$value".ToLower() } elseif ($value -is [string]) { "'$($value.Replace("'", "''"))'" } else { "$value" }
            "    $key = $literal"
        }
        "@{`r`n" + ($lines -join "`r`n") + "`r`n}`r`n"
    }

    # Return the text of a descriptor whose one extent maps the whole VM range of disk 1, with the
    # line ending $Newline.
    function Get-TestDescriptorText {
        param([string]$Newline = "`r`n")
        @('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"', 'CID=fffffffe', 'parentCID=ffffffff',
            'createType="fullDevice"', '', '# Extent description', 'RW 3900000 FLAT "\\.\PhysicalDrive1" 0', '',
            '# The Disk Data Base', '#DDB', '', 'ddb.adapterType = "lsilogic"', '') -join $Newline
    }

    # Return the text of the synthetic .vmx with CRLF line endings: complete, with uuid.action =
    # "keep" and suspend.disabled = "TRUE" unless $Without names their keys, and the lines in $Add.
    function Get-TestVmxText {
        param([string[]]$Without = @(), [string[]]$Add = @())
        $lines = @('.encoding = "windows-1252"', 'config.version = "8"', 'displayName = "Test VM"', 'scsi0:0.fileName = "stick.vmdk"',
            'uuid.action = "keep"', 'suspend.disabled = "TRUE"') | Where-Object { $Without -notcontains ($_ -split ' = ')[0] }
        (@($lines) + $Add + '') -join "`r`n"
    }

    # Create a synthetic stick in TestDrive\$Name and return its paths. Launcher is empty, as no
    # code runs from it in the tests, and LauncherData\settings.psd1 holds Get-TestSettingTable with
    # $Change applied, written as PowerShell data. The VMware folder holds the .vmx and a CRLF
    # descriptor; the VirtualBox home holds VirtualBox.xml and the VM with an LF descriptor, and
    # their paths on the stick carry the drive letter OldLetter. The two programs are empty files
    # below Programs. On Windows the stick's Letter and WindowsPath are those of TestDrive; on
    # another system, where the launcher finds no drive letter, they are made up as T:\TestDrive\
    # <Name>, and Set-TestPc gives the launcher that location.
    function Initialize-TestStick {
        param(
            [string]$Name = 'stick',
            [hashtable]$Change = @{}
        )
        $root = Join-Path $TestDrive $Name
        $windowsPath = if ($script:onWindows) { $root } else { "T:\TestDrive\$Name" }
        $stick = [pscustomobject]@{
            Root           = $root
            Launcher       = Join-Path $root 'Launcher'
            Data           = Join-Path $root 'LauncherData'
            Settings       = Join-Path $root 'LauncherData\settings.psd1'
            Log            = Join-Path $root 'LauncherData\logs\launcher.log'
            Backups        = Join-Path $root 'LauncherData\backups'
            Vmx            = Join-Path $root 'VMware\Test VM.vmx'
            VMwareDisk     = Join-Path $root 'VMware\stick.vmdk'
            Vbox           = Join-Path $root 'VirtualBox\Test VM\Test VM.vbox'
            VirtualBoxXml  = Join-Path $root 'VirtualBox\VirtualBox.xml'
            VirtualBoxDisk = Join-Path $root 'VirtualBox\Test VM\stick.vmdk'
            VMwareDir      = Join-Path $root 'Programs\VMware'
            VirtualBoxDir  = Join-Path $root 'Programs\VirtualBox'
            WindowsPath    = $windowsPath
            Letter         = $windowsPath.Substring(0, 1).ToUpper()
            OldLetter      = if ($windowsPath.Substring(0, 1).ToUpper() -eq 'Q') { 'R' } else { 'Q' }
        }
        $null = New-Item -ItemType Directory -Path $stick.Launcher -Force
        Write-TestFile -Path $stick.Settings -Text (ConvertTo-TestSettingsText -Settings (Get-TestSettingTable -Change $Change))
        Write-TestFile -Path (Join-Path $stick.VMwareDir 'vmware.exe') -Text ''
        Write-TestFile -Path (Join-Path $stick.VirtualBoxDir 'VBoxManage.exe') -Text ''
        Write-TestFile -Path $stick.Vmx -Text (Get-TestVmxText)
        Write-TestFile -Path $stick.VMwareDisk -Text (Get-TestDescriptorText)
        Write-TestFile -Path $stick.VirtualBoxDisk -Text (Get-TestDescriptorText -Newline "`n")
        $below = $windowsPath.Substring(2)
        Write-TestFile -Path $stick.Vbox -Text (@(
                '<?xml version="1.0"?>', '<VirtualBox xmlns="http://www.virtualbox.org/" version="1.19-windows">',
                "  <Machine uuid=`"{$script:uuid}`" name=`"Test VM`" OSType=`"Debian_64`">",
                '    <MediaRegistry><HardDisks>',
                "      <HardDisk uuid=`"{5ca1ab1e-0000-4000-8000-000000000002}`" location=`"$($stick.OldLetter):$below\VirtualBox\Test VM\stick.vmdk`" format=`"VMDK`"/>",
                '    </HardDisks></MediaRegistry>', '  </Machine>', '</VirtualBox>', '') -join "`n")
        Write-TestFile -Path $stick.VirtualBoxXml -Text (@(
                '<?xml version="1.0"?>', '<VirtualBox xmlns="http://www.virtualbox.org/" version="1.12-windows">',
                '  <Global><MachineRegistry>',
                "    <MachineEntry uuid=`"{$script:uuid}`" src=`"$($stick.OldLetter):$($below.Replace('\', '/'))/VirtualBox/Test VM/Test VM.vbox`"/>",
                '  </MachineRegistry></Global>', '</VirtualBox>', '') -join "`n")
        $stick
    }

    # Return the lines of the log $Path without their prefix, each of which must hold this
    # process's ID, and without the Timings lines unless -Timings is given.
    function Get-TestLog {
        param([string]$Path, [switch]$Timings)
        $prefix = '\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[' + $PID + '\]  '
        @(foreach ($line in [IO.File]::ReadAllLines($Path, (Get-TestAnsiEncoding))) {
                if ($line -notmatch $prefix) { throw "A log line lacks the prefix: $line" }
                $message = $line -replace $prefix, ''
                if ($Timings -or -not $message.StartsWith('Timings: ')) { $message }
            })
    }

    # Return the error record that Get-Partition gives for a drive letter that no partition has.
    function Get-TestNoPartitionError {
        [System.Management.Automation.ErrorRecord]::new([Exception]::new('No MSFT_Partition objects found.'), 'CmdletizationQuery_NotFound_DriveLetter,Get-Partition', 'ObjectNotFound', $null)
    }

    # Return the decisions in the log lines $Lines of a run, so that a dry run and a real start of
    # the same case compare equal: the dry run's lines read as the real start's, a would-stop as the
    # stop, after which only the End line counts, and both starts as START.
    function ConvertTo-TestDecision {
        param([string[]]$Lines)
        $cut = $false
        foreach ($line in $Lines) {
            if ($line.StartsWith('----- End')) { $line.Replace('----- End (dry run):', '----- End:'); continue }
            if ($cut) { continue }
            if ($line -ceq '----- Start VM (dry run) -----') { '----- Start VM -----' }
            elseif ($line.StartsWith('DRY RUN - a real start would stop here: ')) { 'STOPPED: ' + $line.Substring(40); $cut = $true }
            elseif ($line.StartsWith('STOPPED: ')) { $line; $cut = $true }
            elseif ($line -match '\ADRY RUN - a real start would ask whether to resume the saved state in (\w+)\.\z') { "Resume of the saved state in $($Matches[1]) confirmed." }
            elseif ($line.StartsWith('DRY RUN - would start ') -or $line.StartsWith('Started with ')) { 'START' }
            elseif ($line.StartsWith('VirtualBox VM state: ')) { continue }
            else { $line }
        }
    }

    # Return a hashtable of every file below $Root, other than those below LauncherData\logs, with
    # its SHA-256 hash.
    function Get-TestTreeHash {
        param([string]$Root)
        $hashes = @{}
        foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]LauncherData[\\/]logs[\\/]' }) {
            $hashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        $hashes
    }

    # Return the processes in $script:testProcesses whose program names, without .exe, are among
    # $Name, as the launcher's process check would find them.
    function Get-TestProcess {
        param([string[]]$Name)
        @($script:testProcesses | Where-Object { $Name -ccontains ($_.Name -replace '\.exe\z', '') })
    }

    # Mock every adapter for a start on the synthetic stick $Stick: the partition with the stick's
    # letter is on disk 3, which is the stick; the processes in $script:testProcesses run, none at
    # first; and the hypervisors in $Installed ('VMware', 'VirtualBox') are installed. VBoxManage
    # lists the VM, reports it powered off and starts it. Outside Windows the stick's location is
    # its made-up drive letter (Initialize-TestStick).
    function Set-TestPc {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that only defines mocks.')]
        param($Stick, [string[]]$Installed = @('VMware', 'VirtualBox'))
        $script:testStick = $Stick
        $script:testInstalled = $Installed
        $script:testProcesses = @()
        Mock -ModuleName PortableVM Write-Host {}
        Mock -ModuleName PortableVM Invoke-PvmTestAdministrator { $true }
        Mock -ModuleName PortableVM Invoke-PvmEnterLock { [pscustomobject]@{ State = 'Acquired'; Mutex = $null } }
        Mock -ModuleName PortableVM Invoke-PvmExitLock {}
        Mock -ModuleName PortableVM Invoke-PvmGetPartition { throw "No partition has the drive letter $DriveLetter." }
        Mock -ModuleName PortableVM Invoke-PvmGetPartition { Get-TestPartition } -ParameterFilter { $DriveLetter -ceq $script:testStick.Letter }
        Mock -ModuleName PortableVM Invoke-PvmGetDisk { throw "No disk has the number $Number." }
        Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk } -ParameterFilter { $Number -eq 3 }
        Mock -ModuleName PortableVM Invoke-PvmGetDeviceGuard { $null }
        Mock -ModuleName PortableVM Invoke-PvmGetProcess { Get-TestProcess -Name $Name }
        if (-not $script:onWindows) {
            Mock -ModuleName PortableVM Get-PvmStickLocation { [pscustomobject]@{ Kind = 'DriveLetter'; Letter = $script:testStick.Letter; Path = $script:testStick.WindowsPath } }
        }
        Mock -ModuleName PortableVM Invoke-PvmTestProcess { $false }
        Mock -ModuleName PortableVM Invoke-PvmStartProcess {}
        Mock -ModuleName PortableVM Invoke-PvmSetEnvironment {}
        Mock -ModuleName PortableVM Invoke-PvmSleep {}
        Mock -ModuleName PortableVM Invoke-PvmGetRegistryValue {
            if ($Path -like '*\Oracle\VirtualBox' -and $script:testInstalled -contains 'VirtualBox') { return $script:testStick.VirtualBoxDir }
            if ($Path -like '*\VMware Workstation' -and $Path -notlike '*WOW6432Node*' -and $script:testInstalled -contains 'VMware') { return $script:testStick.VMwareDir }
            $null
        }
        Mock -ModuleName PortableVM Invoke-PvmNative {
            switch ($ArgumentList[0]) {
                'list' { [pscustomobject]@{ ExitCode = 0; Output = "`"Test VM`" {$script:uuid}" } }
                'showvminfo' { [pscustomobject]@{ ExitCode = 0; Output = "name=`"Test VM`"`nVMState=`"poweroff`"" } }
                'startvm' { [pscustomobject]@{ ExitCode = 0; Output = 'VM has been successfully started.' } }
                '--version' { [pscustomobject]@{ ExitCode = 0; Output = '7.1.4r165100' } }
                default { throw "Unexpected VBoxManage call: $ArgumentList" }
            }
        }
    }
}

AfterAll {
    Remove-Module PortableVM -ErrorAction SilentlyContinue
    $env:PVM_TEST = $script:previousTestFlag
}

Describe 'Adapters' {
    It '<Name> throws when a test reaches it unmocked' -ForEach @(
        @{ Name = 'Invoke-PvmGetPartition'; Call = { Invoke-PvmGetPartition -DriveLetter 'Z' } }
        @{ Name = 'Invoke-PvmGetDisk'; Call = { Invoke-PvmGetDisk -Number 0 } }
        @{ Name = 'Invoke-PvmGetProcess'; Call = { Invoke-PvmGetProcess -Name 'none' } }
        @{ Name = 'Invoke-PvmTestProcess'; Call = { Invoke-PvmTestProcess -Name 'none' } }
        @{ Name = 'Invoke-PvmGetDeviceGuard'; Call = { Invoke-PvmGetDeviceGuard } }
        @{ Name = 'Invoke-PvmGetRegistryValue'; Call = { Invoke-PvmGetRegistryValue -Path 'HKLM:\SOFTWARE\None' -Name 'None' } }
        @{ Name = 'Invoke-PvmNative'; Call = { Invoke-PvmNative -FilePath 'none.exe' } }
        @{ Name = 'Invoke-PvmStartProcess'; Call = { Invoke-PvmStartProcess -FilePath 'none.exe' -ArgumentList 'none' } }
        @{ Name = 'Invoke-PvmSetEnvironment'; Call = { Invoke-PvmSetEnvironment -Name 'PVM_NONE' -Value 'none' } }
        @{ Name = 'Invoke-PvmSleep'; Call = { Invoke-PvmSleep -Seconds 1 } }
        @{ Name = 'Invoke-PvmTestAdministrator'; Call = { Invoke-PvmTestAdministrator } }
        @{ Name = 'Invoke-PvmEnterLock'; Call = { Invoke-PvmEnterLock -Name 'Local\x' } }
        @{ Name = 'Invoke-PvmExitLock'; Call = { Invoke-PvmExitLock -Lock ([pscustomobject]@{ State = 'Acquired'; Mutex = $null }) } }
    ) {
        $Call | Should -Throw -ExpectedMessage "$Name reached this PC during a test; mock it."
    }
}

Describe 'Stops' {
    It 'carry their message through to Get-PvmStopMessage' {
        $message = try { throw (Get-PvmStopException -Message 'stop here') } catch { Get-PvmStopMessage -ErrorRecord $_ }
        $message | Should -BeExactly 'stop here'
    }

    It 'are told apart from other errors' {
        $message = try { throw 'something else' } catch { Get-PvmStopMessage -ErrorRecord $_ }
        $message | Should -BeNullOrEmpty
    }
}

Describe 'Stick identity' {
    It 'accepts the configured stick' {
        Get-PvmStickProblem -Disk (Get-TestDisk) -Partition (Get-TestPartition) -Settings (Get-TestSettingTable) | Should -BeNullOrEmpty
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a GPT disk'; Disk = @{ PartitionStyle = 'GPT' }; Partition = @{}; Message = 'This is not the expected USB stick (disk ID 5CA1AB1E, expected 5CA1AB1E). Nothing was started.' }
        @{ Case = 'another signature'; Disk = @{ Signature = [uint32]0x5CA1AB1F }; Partition = @{}; Message = 'This is not the expected USB stick (disk ID 5CA1AB1F, expected 5CA1AB1E). Nothing was started.' }
        @{ Case = 'a disk without a signature'; Disk = @{ Signature = [uint32]0 }; Partition = @{}; Message = 'This is not the expected USB stick (disk ID none, expected 5CA1AB1E). Nothing was started.' }
        @{ Case = '4096-byte sectors'; Disk = @{ LogicalSectorSize = 4096 }; Partition = @{}; Message = 'The USB stick has an unexpected size. Nothing was started.' }
        @{ Case = 'another size'; Disk = @{ Size = [uint64]4000001 * 512 }; Partition = @{}; Message = 'The USB stick has an unexpected size. Nothing was started.' }
        @{ Case = 'a moved Data partition'; Disk = @{}; Partition = @{ Offset = [uint64]2500001 * 512 }; Message = 'The partition layout of the USB stick has changed; settings.psd1 needs updating. Nothing was started.' }
        @{ Case = 'a resized Data partition'; Disk = @{}; Partition = @{ Size = [uint64]1400001 * 512 }; Message = 'The partition layout of the USB stick has changed; settings.psd1 needs updating. Nothing was started.' }
        @{ Case = "the PC's boot disk"; Disk = @{ IsBoot = $true }; Partition = @{}; Message = "Disk 3 is this PC's Windows disk. Nothing was started." }
        @{ Case = "the PC's system disk"; Disk = @{ IsSystem = $true }; Partition = @{}; Message = "Disk 3 is this PC's Windows disk. Nothing was started." }
    ) {
        Get-PvmStickProblem -Disk (Get-TestDisk -Change $Disk) -Partition (Get-TestPartition -Change $Partition) -Settings (Get-TestSettingTable) |
            Should -BeExactly $Message
    }

    It 'checks the signature before the size' {
        $disk = Get-TestDisk -Change @{ Signature = [uint32]0x5CA1AB1F; LogicalSectorSize = 4096 }
        Get-PvmStickProblem -Disk $disk -Partition (Get-TestPartition) -Settings (Get-TestSettingTable) | Should -BeLike 'This is not the expected USB stick*'
    }
}

Describe 'Host-neutral rules' {
    It 'take the host for Windows exactly where .NET says so' {
        Test-PvmWindowsHost | Should -Be $script:onWindows
    }

    Context 'for paths' {
        It 'forbid in a name the characters Windows forbids, on every system' {
            $chars = Get-PvmForbiddenNameChar
            $chars | Should -BeOfType ([char])
            $codes = @($chars | ForEach-Object { [int]$_ } | Sort-Object)
            $codes | Should -Be @(@(0..31) + @(34, 42, 47, 58, 60, 62, 63, 92, 124))
            if ($script:onWindows) { $codes | Should -Be @([IO.Path]::GetInvalidFileNameChars() | ForEach-Object { [int]$_ } | Sort-Object) }
        }

        It 'join a path setting to the stick folder with this system''s separator: <Value>' -ForEach @(
            @{ Value = 'VMware\Test VM.vmx' }, @{ Value = 'VMware/Test VM.vmx' }, @{ Value = 'a b\c d/Test VM.vmx' }
        ) {
            $root = Join-Path $TestDrive 'stick'
            $joined = Join-PvmStickPath -Root $root -Path $Value
            # On Windows exactly what Join-Path gave before, so no path the launcher uses changes there.
            if ($script:onWindows) { $joined | Should -BeExactly (Join-Path $root $Value) }
            else { $joined | Should -BeExactly ($root + '/' + $Value.Replace('\', '/')) }
        }

        It 'keep a file''s first version below the stick folder only in the case its name has, where the system compares names so' {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $false }
            $root = Join-Path $TestDrive 'Stick'
            $backups = Join-Path $root 'LauncherData'
            { Get-PvmBackupPath -Root $root -Backups $backups -Path (Join-Path (Join-Path $TestDrive 'stick') 'x.vmdk') -Suffix '.orig' } | Should -Throw
            Get-PvmBackupPath -Root $root -Backups $backups -Path (Join-Path $root 'x.vmdk') -Suffix '.orig' | Should -BeExactly (Join-Path $backups 'x.vmdk.orig')
        }

        It 'keep a file''s first version below the stick folder in any case on Windows' {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $true }
            $root = Join-Path $TestDrive 'Stick'
            $backups = Join-Path $root 'LauncherData'
            $path = Join-Path (Join-Path $TestDrive 'stick') 'x.vmdk'
            if ($script:onWindows) { Get-PvmBackupPath -Root $root -Backups $backups -Path $path -Suffix '.orig' | Should -BeExactly (Join-Path $backups 'x.vmdk.orig') }
        }
    }

    Context 'for missing files' {
        It 'say on a system that compares names in case that the name must match in case: <Program>' -ForEach @(
            @{ Program = 'VMware'; File = 'none.vmx' }, @{ Program = 'VirtualBox'; File = 'none.vbox' }
        ) {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $false }
            $path = Join-Path $TestDrive $File
            $state = if ($Program -eq 'VMware') { Get-PvmVMwareState -Path $path } else { Get-PvmVirtualBoxState -Path $path }
            $state.Reason | Should -BeExactly 'the file does not exist, and on this system the name in settings.psd1 must match its case'
        }

        It 'say on Windows only that the file does not exist' {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $true }
            (Get-PvmVMwareState -Path (Join-Path $TestDrive 'none.vmx')).Reason | Should -BeExactly 'the file does not exist'
            (Get-PvmVirtualBoxState -Path (Join-Path $TestDrive 'none.vbox')).Reason | Should -BeExactly 'the file does not exist'
        }
    }

    Context 'for raw-disk descriptors' {
        It 'read a FLAT extent that names a device below /dev as a raw disk' {
            $lines = @(ConvertFrom-PvmDescriptorText -Text "createType=`"fullDevice`"`nRW 3900000 FLAT `"/dev/sdb`" 0`n")
            $extent = @($lines | Where-Object { $_.Kind -eq 'Extent' })
            $extent.Count | Should -Be 1
            $extent[0].Target | Should -BeExactly '/dev/sdb'
        }

        It 'refuse a FLAT extent that names <Target>, which is no device' -ForEach @(
            @{ Target = '/dev/' }, @{ Target = '/devices/sdb' }, @{ Target = 'dev/sdb' }, @{ Target = '/srv/vm/stick-flat.vmdk' }
            @{ Target = '/dev/../srv/vm' }, @{ Target = '/dev/./sdb' }, @{ Target = '/DEV/sdb' }
        ) {
            $thrown = try { $null = ConvertFrom-PvmDescriptorText -Text "RW 9 FLAT `"$Target`" 0" } catch { $_ }
            $thrown.Exception.Message | Should -BeExactly 'line 1 has a FLAT extent that names a file, not a raw disk'
        }

        It 'refuse a /dev path with <Shape>, which can lead out of /dev: <Target>' -ForEach @(
            @{ Shape = 'a .. in the middle'; Target = '/dev/sdb/../../srv/vm/stick-flat.vmdk' }
            @{ Shape = 'a .. after a device folder'; Target = '/dev/disk/by-id/../../../srv/vm/flat.vmdk' }
            @{ Shape = 'a trailing ..'; Target = '/dev/disk/..' }
            @{ Shape = 'a trailing .'; Target = '/dev/disk/.' }
            @{ Shape = 'a . in the middle'; Target = '/dev/disk/./sdb' }
            @{ Shape = 'a trailing separator'; Target = '/dev/sdb/' }
            @{ Shape = 'an empty name'; Target = '/dev//sdb' }
            @{ Shape = 'mixed separators with ..'; Target = '/dev/sdb\..\..\srv\vm\flat.vmdk' }
            @{ Shape = 'mixed separators'; Target = '/dev/disk\by-id/sdb' }
            @{ Shape = 'a backslash for the first separator'; Target = '/dev\sdb' }
        ) {
            Test-PvmRawDeviceTarget -Target $Target | Should -BeFalse
            $thrown = try { $null = ConvertFrom-PvmDescriptorText -Text "RW 9 FLAT `"$Target`" 0" } catch { $_ }
            $thrown.Exception.Message | Should -BeExactly 'line 1 has a FLAT extent that names a file, not a raw disk'
            # The disarm step leaves a target it does not take for a device as it is.
            ConvertTo-PvmDisarmedDescriptorText -Text "RW 9 FLAT `"$Target`" 0" | Should -BeExactly "RW 9 FLAT `"$Target`" 0"
        }

        It 'take a /dev path of names without . or .. as a raw disk: <Target>' -ForEach @(
            @{ Target = '/dev/sdb' }, @{ Target = '/dev/nvme0n1' }, @{ Target = '/dev/disk/by-id/usb-Test_Stick_0-0:0' }, @{ Target = '/dev/mapper/..stick' }
        ) {
            Test-PvmRawDeviceTarget -Target $Target | Should -BeTrue
        }

        It 'name the disarmed device in the spelling of the device it replaces: <Target>' -ForEach @(
            @{ Target = '\\.\PhysicalDrive1'; Device = '\\.\PortableVM-disarmed' }
            @{ Target = '\\?\PhysicalDrive1'; Device = '\\.\PortableVM-disarmed' }
            @{ Target = '/dev/sdb'; Device = '/dev/PortableVM-disarmed' }
        ) {
            Get-PvmDisarmedDevice -Target $Target | Should -BeExactly $Device
        }

        It 'disarm a /dev target in its own spelling and leave both disarmed spellings as they are' {
            $text = "RW 10 FLAT `"/dev/sdb`" 0`r`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`nRW 3 FLAT `"/dev/PortableVM-disarmed`" 0`nRW 4 FLAT `"\\.\PortableVM-disarmed`" 0`nRW 1 FLAT `"/srv/vm/flat.vmdk`" 0`n"
            $disarmed = ConvertTo-PvmDisarmedDescriptorText -Text $text
            $disarmed | Should -BeExactly ("RW 10 FLAT `"/dev/PortableVM-disarmed`" 0`r`nRW 2 FLAT `"\\.\PortableVM-disarmed`" 0`nRW 3 FLAT `"/dev/PortableVM-disarmed`" 0`n" +
                "RW 4 FLAT `"\\.\PortableVM-disarmed`" 0`nRW 1 FLAT `"/srv/vm/flat.vmdk`" 0`n")
            ConvertTo-PvmDisarmedDescriptorText -Text $disarmed | Should -BeExactly $disarmed
        }

        It 'come back byte for byte after a disarm and an arm, and disarm the same again: <Case>' -ForEach @(
            @{ Case = 'a Windows descriptor'; Device = '\\.\PhysicalDrive1'; Spelled = '\\.\PortableVM-disarmed' }
            @{ Case = 'a Linux descriptor'; Device = '/dev/sdb'; Spelled = '/dev/PortableVM-disarmed' }
        ) {
            $original = (Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', $Device)
            $disarmed = ConvertTo-PvmDisarmedDescriptorText -Text $original
            $disarmed | Should -BeExactly ((Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', $Spelled))
            $armed = ConvertTo-PvmDescriptorText -Text $disarmed -Layout @{ CreateType = 'fullDevice'; Extents = @("RW 3900000 FLAT `"$Device`" 0") }
            $armed | Should -BeExactly $original
            ConvertTo-PvmDisarmedDescriptorText -Text $armed | Should -BeExactly $disarmed
        }

        It 'arm a descriptor that names a /dev device for the stick''s raw disk on Windows' {
            $text = (Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', '/dev/sdb')
            ConvertTo-PvmDescriptorText -Text $text -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive3" 0') } |
                Should -BeExactly ((Get-TestDescriptorText).Replace('PhysicalDrive1', 'PhysicalDrive3'))
        }
    }

    Context 'for the stick''s location' {
        It 'is the drive letter and the stick folder of a launcher on a drive: <Path>' -Tag 'WindowsOnly' -ForEach @(
            @{ Path = 'X:\Launcher'; Root = 'X:\'; Letter = 'X' }
            @{ Path = 'x:\Sticks\One\Launcher'; Root = 'x:\Sticks\One'; Letter = 'X' }
        ) {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $true }
            $location = Get-PvmStickLocation -LauncherPath $Path -Root $Root
            $location.Kind | Should -BeExactly 'DriveLetter'
            $location.Letter | Should -BeExactly $Letter
            $location.Path | Should -BeExactly $Root
        }

        It 'is none for a launcher without a drive letter: <Path>' -ForEach @(
            @{ Path = '\\server\share\Launcher'; Root = '\\server\share' }
            @{ Path = '\\?\X:\Launcher'; Root = '\\?\X:\' }
            @{ Path = 'X:Launcher'; Root = 'X:' }
        ) {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $true }
            Get-PvmStickLocation -LauncherPath $Path -Root $Root | Should -BeNullOrEmpty
        }

        It 'is none on a system other than Windows, for any path' -ForEach @(
            @{ Path = 'X:\Launcher'; Root = 'X:\' }, @{ Path = '/media/user/STICK/Launcher'; Root = '/media/user/STICK' }
        ) {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $false }
            Get-PvmStickLocation -LauncherPath $Path -Root $Root | Should -BeNullOrEmpty
        }

        It 'gives the partition, the disk and the raw device of a stick on a drive letter' {
            Mock -ModuleName PortableVM Invoke-PvmGetPartition { Get-TestPartition } -ParameterFilter { $DriveLetter -ceq 'E' }
            Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk } -ParameterFilter { $Number -eq 3 }
            $stick = Get-PvmStickDevice -Location ([pscustomobject]@{ Kind = 'DriveLetter'; Letter = 'E'; Path = 'E:\' }) -Names @{ VM = 'the VM'; Guest = 'the guest' }
            $stick.Device | Should -BeExactly '\\.\PhysicalDrive3'
            $stick.Disk.Number | Should -Be 3
            $stick.Partition.Offset | Should -Be ([uint64]2500000 * 512)
        }

        It 'names the raw device of disk <Number> as Windows does' -ForEach @(@{ Number = 0 }, @{ Number = 3 }, @{ Number = 12 }) {
            Get-PvmRawDevice -Disk ([pscustomobject]@{ Number = [uint32]$Number }) | Should -BeExactly "\\.\PhysicalDrive$Number"
        }
    }

    Context 'for running programs' {
        It 'ask Windows for the processes of the program names <Names> as before, with .exe' -ForEach @(
            @{ Names = @('vmware-vmx'); Filter = "Name='vmware-vmx.exe'" }
            @{ Names = @('VirtualBoxVM', 'VBoxHeadless'); Filter = "Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'" }
            @{ Names = @('VirtualBox', 'VirtualBoxVM', 'VBoxHeadless'); Filter = "Name='VirtualBox.exe' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'" }
        ) {
            ConvertTo-PvmProcessFilter -Name $Names | Should -BeExactly $Filter
        }
    }
}

Describe 'Safe writes' -Tag 'WindowsOnly' {
    BeforeAll {
        # Return the names in the test folder, hidden ones included.
        function Get-TestName { @(Get-ChildItem -LiteralPath $script:folder -Force -Name | Sort-Object) }

        # Return the code a refusal of Write-PvmFile carries, or the exception's type for another
        # error, from the script block $Write.
        function Get-TestWriteError {
            param([scriptblock]$Write)
            try { $null = & $Write; '' }
            catch {
                if ($_.Exception.Data['PvmWrite']) { $_.Exception.Data['PvmWrite'] } else { $_.Exception.GetType().Name }
            }
        }
    }

    BeforeEach {
        $script:folder = Join-Path $TestDrive 'writes'
        if (Test-Path -LiteralPath $script:folder) {
            Get-ChildItem -LiteralPath $script:folder -Force | ForEach-Object { $_.Attributes = 'Normal' }
            Remove-Item -LiteralPath $script:folder -Recurse -Force
        }
        $null = [IO.Directory]::CreateDirectory($script:folder)
        $script:file = Join-Path $script:folder 'stick.vmdk'
        $script:oldBytes = [Text.Encoding]::ASCII.GetBytes("old`r`n")
        $script:newBytes = [Text.Encoding]::ASCII.GetBytes("new text`r`n")
    }

    It 'create a new file with exactly the bytes, and leave nothing beside it' {
        Write-PvmFile -Path $script:file -Bytes $script:newBytes | Should -BeExactly ''
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:file)) -Right $script:newBytes | Should -BeTrue
        Get-TestName | Should -BeExactly @('stick.vmdk')
    }

    It 'never replace an item in create mode: <Case>' -ForEach @(
        @{ Case = 'a file'; Setup = { [IO.File]::WriteAllBytes($script:file, $script:oldBytes) } }
        @{ Case = 'a folder'; Setup = { $null = [IO.Directory]::CreateDirectory($script:file) } }
    ) {
        & $Setup
        Get-TestWriteError { Write-PvmFile -Path $script:file -Bytes $script:newBytes } | Should -BeExactly 'Exists'
        Get-TestName | Should -BeExactly @('stick.vmdk')
    }

    It 'replace a file that still holds the bytes read, keeping its attributes and creation time, and leave nothing beside it' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        $created = [DateTime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
        [IO.File]::SetCreationTimeUtc($script:file, $created)
        [IO.File]::SetAttributes($script:file, [IO.FileAttributes]'Hidden, Archive')
        Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes | Should -BeExactly ''
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:file)) -Right $script:newBytes | Should -BeTrue
        [IO.File]::GetAttributes($script:file) -band [IO.FileAttributes]::Hidden | Should -Be ([IO.FileAttributes]::Hidden)
        [IO.File]::GetCreationTimeUtc($script:file) | Should -Be $created
        Get-TestName | Should -BeExactly @('stick.vmdk')
    }

    It 'replace an empty file and write an empty one' {
        [IO.File]::WriteAllBytes($script:file, [byte[]]@())
        Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected ([byte[]]@()) | Should -BeExactly ''
        Write-PvmFile -Path $script:file -Bytes ([byte[]]@()) -Expected $script:newBytes | Should -BeExactly ''
        [IO.File]::ReadAllBytes($script:file).Length | Should -Be 0
    }

    It 'refuse <Case>, and change nothing' -ForEach @(
        @{ Case = 'a missing file in replace mode'; Code = 'Missing'; Names = @(); Setup = {} }
        @{ Case = 'a folder in replace mode'; Code = 'NotAFile'; Names = @('stick.vmdk'); Setup = { $null = [IO.Directory]::CreateDirectory($script:file) } }
        @{ Case = 'a read-only file'; Code = 'ReadOnly'; Names = @('stick.vmdk'); Setup = {
                [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
                [IO.File]::SetAttributes($script:file, [IO.FileAttributes]::ReadOnly)
            }
        }
        @{ Case = 'a file that changed since it was read'; Code = 'Changed'; Names = @('stick.vmdk'); Setup = {
                [IO.File]::WriteAllBytes($script:file, [Text.Encoding]::ASCII.GetBytes("changed`r`n"))
            }
        }
    ) {
        & $Setup
        $before = if ([IO.File]::Exists($script:file)) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:file)) } else { '' }
        Get-TestWriteError { Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes } | Should -BeExactly $Code
        Get-TestName | Should -BeExactly $Names
        $after = if ([IO.File]::Exists($script:file)) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:file)) } else { '' }
        $after | Should -BeExactly $before
    }

    It 'stop at a write that was cut off, with <Left> beside the file, and change nothing' -ForEach @(
        @{ Left = 'stick.vmdk.pvm-tmp' }
        @{ Left = 'stick.vmdk.pvm-old' }
    ) {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        [IO.File]::WriteAllBytes((Join-Path $script:folder $Left), $script:newBytes)
        Get-TestWriteError { Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes } | Should -BeExactly 'Leftover'
        Get-TestWriteError { Write-PvmFile -Path (Join-Path $script:folder 'other.vmdk') -Bytes $script:newBytes } | Should -BeExactly ''
        Get-TestName | Should -BeExactly @(@('other.vmdk', 'stick.vmdk', $Left) | Sort-Object)
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:file)) -Right $script:oldBytes | Should -BeTrue
    }

    It 'give its refusals a message that names no path, with the path in the details' {
        $thrown = try { Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes } catch { $_ }
        $thrown.Exception | Should -BeOfType ([System.Management.Automation.RuntimeException])
        $thrown.Exception.InnerException | Should -BeNullOrEmpty
        $thrown.Exception.Message.Contains($script:folder) | Should -BeFalse
        "$($thrown.Exception.Data['PvmDetail'])".Contains($script:file) | Should -BeTrue
    }

    It 'leave the file and remove its own new copy when the swap fails' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        Mock -ModuleName PortableVM Switch-PvmFile { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) }
        Get-TestWriteError { Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes } | Should -BeExactly 'IOException'
        Get-TestName | Should -BeExactly @('stick.vmdk')
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:file)) -Right $script:oldBytes | Should -BeTrue
    }

    It 'keep both versions when the swap leaves the file missing, for the step by hand' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        # Windows' error 1177: the file went to its old name, but the new copy did not take its place.
        Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Move($Path, $Old); throw [IO.IOException]::new('Unable to move the replacement file.', [int]0x80070499) }
        Get-TestWriteError { Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes } | Should -BeExactly 'IOException'
        Get-TestName | Should -BeExactly @('stick.vmdk.pvm-old', 'stick.vmdk.pvm-tmp')
        Get-PvmLeftoverProblem -Path $script:file | Should -BeLike '*rename stick.vmdk.pvm-old back to stick.vmdk and remove stick.vmdk.pvm-tmp*'
    }

    It 'try three times, a second apart, to remove the old version, and return its name when it cannot, keeping the new one' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        Mock -ModuleName PortableVM Invoke-PvmSleep {}
        Mock -ModuleName PortableVM Remove-PvmWriteCopy { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) } -ParameterFilter { $Path -like '*.pvm-old' }
        Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes | Should -BeExactly "$script:file.pvm-old"
        Should -Invoke -CommandName Remove-PvmWriteCopy -ModuleName PortableVM -Times 3 -Exactly
        Should -Invoke -CommandName Invoke-PvmSleep -ModuleName PortableVM -Times 2 -Exactly -ParameterFilter { $Seconds -eq 1 }
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:file)) -Right $script:newBytes | Should -BeTrue
        Get-TestName | Should -BeExactly @('stick.vmdk', 'stick.vmdk.pvm-old')
    }

    It 'remove the old version at a later try when something held it for a moment' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        Mock -ModuleName PortableVM Invoke-PvmSleep {}
        $script:tries = 0
        Mock -ModuleName PortableVM Remove-PvmWriteCopy {
            $script:tries++
            if ($script:tries -eq 1) { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) }
            [IO.File]::Delete($Path)
        }
        Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes | Should -BeExactly ''
        Get-TestName | Should -BeExactly @('stick.vmdk')
    }

    It 'keep both versions when the new one does not read back from its place, with the step that puts the version before back' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        # The swap works, but something changes the file before it is read back.
        Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Replace($Temp, $Path, $Old); [IO.File]::AppendAllText($Path, 'changed') }
        $thrown = try { Write-PvmFile -Path $script:file -Bytes $script:newBytes -Expected $script:oldBytes } catch { $_ }
        $thrown.Exception.Data['PvmWrite'] | Should -BeExactly 'ReadBack'
        "$($thrown.Exception.Data['PvmDetail'])" | Should -BeExactly ("$script:file did not read back as written after it took the file's place. A write of $script:file did not finish. " +
            'To set it right, remove stick.vmdk, then rename stick.vmdk.pvm-old back to stick.vmdk, which holds the version before the write.')
        Get-TestName | Should -BeExactly @('stick.vmdk', 'stick.vmdk.pvm-old')
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes("$script:file.pvm-old")) -Right $script:oldBytes | Should -BeTrue
    }

    It 'name, beside a copy put back whose swap stopped between its renames, the step that keeps the copy put back' {
        # The copy's name is free, its version before repeats the file as it is now, and the new copy is the one put back.
        [IO.File]::WriteAllBytes("$script:file.pvm-old", $script:newBytes)
        [IO.File]::WriteAllBytes("$script:file.pvm-tmp", $script:oldBytes)
        Get-PvmLeftoverProblem -Path $script:file -Current $script:newBytes | Should -BeExactly ("A write of $script:file did not finish. To set it right, rename stick.vmdk.pvm-tmp " +
            'to stick.vmdk and remove stick.vmdk.pvm-old, which holds a copy of the file as it is now.')
        Get-PvmLeftoverProblem -Path $script:file -Current $script:oldBytes |
            Should -BeExactly "A write of $script:file did not finish. To set it right, rename stick.vmdk.pvm-old back to stick.vmdk and remove stick.vmdk.pvm-tmp."
    }

    It 'name a step that needs no guess when the version before beside a copy cannot be read' {
        [IO.File]::WriteAllBytes($script:file, $script:oldBytes)
        [IO.File]::WriteAllBytes("$script:file.pvm-old", $script:newBytes)
        $held = [IO.File]::Open("$script:file.pvm-old", 'Open', 'Read', 'None')
        try { $problem = Get-PvmLeftoverProblem -Path $script:file -Current $script:newBytes }
        finally { $held.Dispose() }
        $problem | Should -BeExactly "A write of $script:file did not finish, and stick.vmdk.pvm-old beside it cannot be read. Close the program that holds it, then start again."
    }

    It 'name the one step that sets right a write that did not finish: <Case>' -ForEach @(
        @{ Case = 'nothing left'; Names = @('stick.vmdk'); Step = '' }
        @{ Case = 'a new copy beside the file'; Names = @('stick.vmdk', 'stick.vmdk.pvm-tmp'); Step = 'remove stick.vmdk.pvm-tmp; stick.vmdk itself is whole' }
        @{ Case = 'the version before beside the file'; Names = @('stick.vmdk', 'stick.vmdk.pvm-old')
            Step = 'remove stick.vmdk, then rename stick.vmdk.pvm-old back to stick.vmdk, which holds the version before the write'
        }
        @{ Case = 'both beside the file'; Names = @('stick.vmdk', 'stick.vmdk.pvm-old', 'stick.vmdk.pvm-tmp'); Step = 'remove stick.vmdk.pvm-tmp and stick.vmdk.pvm-old; stick.vmdk itself is whole' }
        @{ Case = 'the version before alone'; Names = @('stick.vmdk.pvm-old'); Step = 'rename stick.vmdk.pvm-old back to stick.vmdk' }
        @{ Case = 'the version before and a new copy'; Names = @('stick.vmdk.pvm-old', 'stick.vmdk.pvm-tmp'); Step = 'rename stick.vmdk.pvm-old back to stick.vmdk and remove stick.vmdk.pvm-tmp' }
        @{ Case = 'a new copy alone'; Names = @('stick.vmdk.pvm-tmp'); Step = 'remove stick.vmdk.pvm-tmp, which may be incomplete' }
    ) {
        foreach ($name in $Names) { [IO.File]::WriteAllBytes((Join-Path $script:folder $name), $script:oldBytes) }
        $problem = Get-PvmLeftoverProblem -Path $script:file
        if ($Step) { $problem | Should -BeExactly "A write of $script:file did not finish. To set it right, $Step." } else { $problem | Should -BeExactly '' }
    }
}

Describe 'Raw-disk descriptors' {
    It 'map the whole VM range when the Data partition is shown' {
        $layout = Get-PvmDiskLayout -Drive '\\.\PhysicalDrive3' -VmSectors 3900000 -DataPartitionStart 2500000 -HideData $false
        $layout.CreateType | Should -BeExactly 'fullDevice'
        $layout.Extents | Should -BeExactly @('RW 3900000 FLAT "\\.\PhysicalDrive3" 0')
    }

    It 'blank the Data partition when it is hidden' {
        $layout = Get-PvmDiskLayout -Drive '\\.\PhysicalDrive3' -VmSectors 3900000 -DataPartitionStart 2500000 -HideData $true
        $layout.CreateType | Should -BeExactly 'partitionedDevice'
        $layout.Extents | Should -BeExactly @('RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO')
    }

    It 'replace the extents and createType and keep every other line and CRLF' {
        $layout = @{ CreateType = 'partitionedDevice'; Extents = @('RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO') }
        $new = ConvertTo-PvmDescriptorText -Text (Get-TestDescriptorText) -Layout $layout
        $new | Should -BeExactly (@('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"', 'CID=fffffffe', 'parentCID=ffffffff',
                'createType="partitionedDevice"', '', '# Extent description', 'RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO', '',
                '# The Disk Data Base', '#DDB', '', 'ddb.adapterType = "lsilogic"', '') -join "`r`n")
    }

    It 'write all new extents where the old ones were, read in any case, and keep LF' {
        $text = "createType=`"x`"`nrw 10 flat `"\\.\PhysicalDrive1`" 0`nRDONLY 5 ZERO`nNOACCESS 2 FLAT `"\\?\PhysicalDrive2`" 7`nddb.x = `"1`""
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 17 FLAT "\\.\PhysicalDrive3" 0') }
        ConvertTo-PvmDescriptorText -Text $text -Layout $layout |
            Should -BeExactly "createType=`"fullDevice`"`nRW 17 FLAT `"\\.\PhysicalDrive3`" 0`nddb.x = `"1`""
    }

    It 'keep the ending of each line, and give new lines the ending of the old extents' {
        $text = "version=1`r`ncreateType=`"fullDevice`"`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n# end`n"
        $layout = @{ CreateType = 'partitionedDevice'; Extents = @('RW 2 FLAT "\\.\PhysicalDrive3" 0', 'RW 7 ZERO') }
        ConvertTo-PvmDescriptorText -Text $text -Layout $layout |
            Should -BeExactly "version=1`r`ncreateType=`"partitionedDevice`"`nRW 2 FLAT `"\\.\PhysicalDrive3`" 0`r`nRW 7 ZERO`r`n# end`n"
    }

    It 'refuse a descriptor the launcher does not understand: <Case>' -ForEach @(
        @{ Case = 'no extent'; Text = "createType=`"fullDevice`""; Reason = 'no disk extent found' }
        @{ Case = 'a sparse extent'; Text = "createType=`"monolithicSparse`"`nRW 17 SPARSE `"disk.vmdk`""; Reason = 'line 2 has a SPARSE extent, and the launcher rewrites only FLAT and ZERO extents' }
        @{ Case = 'an extent line it cannot read'; Text = "RW 17 FLAT"; Reason = 'line 1 is an extent line the launcher cannot read' }
        @{ Case = 'a FLAT extent that names a file'; Text = "RW 63 FLAT `"stick-pt.vmdk`" 0"; Reason = 'line 1 has a FLAT extent that names a file, not a raw disk' }
        @{ Case = 'a FLAT extent without an offset'; Text = "RW 63 FLAT `"\\.\PhysicalDrive1`""; Reason = 'line 1 has a FLAT extent without an offset' }
        @{ Case = 'a ZERO extent with a target'; Text = "RW 63 ZERO `"\\.\PhysicalDrive1`" 0"; Reason = 'line 1 has a ZERO extent that names a target' }
        @{ Case = 'extents apart'; Text = "RW 9 FLAT `"\\.\PhysicalDrive1`" 0`n# between`nRW 2 ZERO"; Reason = 'line 3 is an extent apart from the others' }
        @{ Case = 'createType twice'; Text = "createType=`"fullDevice`"`ncreateType=`"fullDevice`"`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0"; Reason = 'line 2 sets createType a second time' }
        @{ Case = 'a line of no known kind'; Text = "RW 9 FLAT `"\\.\PhysicalDrive1`" 0`nthis is no descriptor"; Reason = 'line 2 is no descriptor line' }
    ) {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 17 FLAT "\\.\PhysicalDrive3" 0') }
        $thrown = try { $null = ConvertTo-PvmDescriptorText -Text $Text -Layout $layout } catch { $_ }
        $thrown.Exception | Should -BeOfType ([FormatException])
        $thrown.Exception.Message | Should -BeExactly $Reason
    }

    It 'insert a createType line where a descriptor has none: <Case>' -ForEach @(
        @{ Case = 'without a header'; Text = "RW 9 FLAT `"\\.\PhysicalDrive1`" 0"; New = "createType=`"fullDevice`"`nRW 17 FLAT `"\\.\PhysicalDrive3`" 0" }
        @{ Case = 'after the last header line'
            Text = "# Disk DescriptorFile`r`nversion=1`r`nCID=fffffffe`r`nparentCID=ffffffff`r`n`r`n# Extent description`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
            New = "# Disk DescriptorFile`r`nversion=1`r`nCID=fffffffe`r`nparentCID=ffffffff`r`ncreateType=`"fullDevice`"`r`n`r`n# Extent description`r`nRW 17 FLAT `"\\.\PhysicalDrive3`" 0`r`n"
        }
    ) {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 17 FLAT "\\.\PhysicalDrive3" 0') }
        ConvertTo-PvmDescriptorText -Text $Text -Layout $layout | Should -BeExactly $New
    }

    It 'read descriptor bytes one character per byte, so a rewrite keeps every other byte' {
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("# caf") + @(0xE9) + [Text.Encoding]::ASCII.GetBytes("`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"))
        $text = ConvertFrom-PvmDescriptorData -Bytes $bytes
        $text.Length | Should -Be $bytes.Length
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 9 FLAT "\\.\PhysicalDrive3" 0') }
        $new = [Text.Encoding]::GetEncoding(28591).GetBytes((ConvertTo-PvmDescriptorText -Text $text -Layout $layout))
        $expected = [byte[]](@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("# caf") + @(0xE9) +
            [Text.Encoding]::ASCII.GetBytes("`r`ncreateType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive3`" 0`r`n"))
        [Convert]::ToBase64String($new) | Should -BeExactly ([Convert]::ToBase64String($expected))
    }

    It 'refuse descriptor bytes that are no descriptor text: <Case>' -ForEach @(
        @{ Case = 'a sparse disk'; Bytes = [byte[]][char[]]'KDMV....'; Reason = 'it is a disk image, not a descriptor' }
        @{ Case = 'an old sparse disk'; Bytes = [byte[]][char[]]'COWD....'; Reason = 'it is a disk image, not a descriptor' }
        @{ Case = 'UTF-16 text'; Bytes = [byte[]](0xFF, 0xFE, 0x52, 0x00); Reason = 'it is UTF-16 or UTF-32 text, not descriptor text' }
        @{ Case = 'a NUL byte'; Bytes = [byte[]](0x52, 0x57, 0x00, 0x20); Reason = 'it holds a NUL byte, which descriptor text never has' }
    ) {
        $thrown = try { $null = ConvertFrom-PvmDescriptorData -Bytes $Bytes } catch { $_ }
        $thrown.Exception | Should -BeOfType ([FormatException])
        $thrown.Exception.Message | Should -BeExactly $Reason
    }

    It 'refuse descriptor bytes of 1 MiB or more' {
        $thrown = try { $null = ConvertFrom-PvmDescriptorData -Bytes (New-Object byte[] 1MB) } catch { $_ }
        $thrown.Exception.Message | Should -BeExactly 'it holds 1 MiB or more, which no descriptor does'
    }

    It 'are created for VMware with a fixed IDE disk database and CRLF' {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO') }
        Get-PvmVMwareDescriptorText -Layout $layout | Should -BeExactly (@('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"',
                'CID=fffffffe', 'parentCID=ffffffff', 'createType="fullDevice"', '', '# Extent description',
                'RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO', '', '# The Disk Data Base', '#DDB', '',
                'ddb.adapterType = "ide"', 'ddb.geometry.cylinders = "16383"', 'ddb.geometry.heads = "16"', 'ddb.geometry.sectors = "63"',
                'ddb.virtualHWVersion = "20"', '') -join "`r`n")
    }

    It 'disarm every FLAT extent that names a raw device, in any case, and keep every other line and line ending' {
        $text = ("createType=`"fullDevice`"`r`nRW 10 FLAT `"\\.\PhysicalDrive1`" 0`r`nrw 5 flat `"\\?\PhysicalDrive2`" 7`n" +
            "RDONLY 4 FLAT `"\\.\Harddisk3Partition1`" 0`r`nNOACCESS 3 FLAT `"\\?\GLOBALROOT\Device\Harddisk1\Partition0`" 0`r`n" +
            "RW 2 FLAT `"\\.\portablevm-disarmed`" 0`r`nRW 1 FLAT `"stick-flat.vmdk`" 0`r`nRW 6 ZERO`r`n# PhysicalDrive1`r`n")
        $disarmed = ConvertTo-PvmDisarmedDescriptorText -Text $text
        $disarmed | Should -BeExactly ("createType=`"fullDevice`"`r`nRW 10 FLAT `"\\.\PortableVM-disarmed`" 0`r`nrw 5 flat `"\\.\PortableVM-disarmed`" 7`n" +
            "RDONLY 4 FLAT `"\\.\PortableVM-disarmed`" 0`r`nNOACCESS 3 FLAT `"\\.\PortableVM-disarmed`" 0`r`n" +
            "RW 2 FLAT `"\\.\portablevm-disarmed`" 0`r`nRW 1 FLAT `"stick-flat.vmdk`" 0`r`nRW 6 ZERO`r`n# PhysicalDrive1`r`n")
        ConvertTo-PvmDisarmedDescriptorText -Text $disarmed | Should -BeExactly $disarmed
    }

    It 'arm a disarmed copy again when it is pointed at the stick' {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive3" 0') }
        $disarmed = ConvertTo-PvmDisarmedDescriptorText -Text (Get-TestDescriptorText)
        ConvertTo-PvmDescriptorText -Text $disarmed -Layout $layout | Should -BeExactly ((Get-TestDescriptorText).Replace('PhysicalDrive1', 'PhysicalDrive3'))
    }

    # VMware ends an extent line with a blank when it writes the descriptor, and a rewrite only for
    # that would replace the copy of the version before it at every VMware start.
    It 'count descriptors as the same when they differ only in <Case>' -ForEach @(
        @{ Case = "VMware's blank at the end of a FLAT extent line"
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0 `r`n# end`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n# end`r`n"
        }
        @{ Case = 'blanks and tabs at the end of a FLAT extent line'
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0 `t `r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'a blank at the end of a ZERO extent line, with LF'
            Old = "createType=`"partitionedDevice`"`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`nRW 7 ZERO `nddb.x = `"1`"`n"
            New = "createType=`"partitionedDevice`"`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`nRW 7 ZERO`nddb.x = `"1`"`n"
        }
        @{ Case = 'a blank at the end of the createType line'
            Old = "createType=`"fullDevice`" `r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'a blank at the end of a last extent line without a line ending'
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0 "
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0"
        }
        @{ Case = 'case, as before the redesign'
            Old = "createType=`"fullDevice`"`r`nrw 9 flat `"\\.\physicaldrive1`" 0`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
    ) {
        Test-PvmSameDescriptorText -Old $Old -New $New | Should -BeTrue
    }

    # {0} in Old stands at the end of the line that differs, and takes each of the blanks in turn.
    It 'never count descriptors as the same when they differ in <Case>, whatever blanks end the line' -ForEach @(
        @{ Case = 'the device target'
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive3`" 0`r`n"
        }
        @{ Case = 'the size of a FLAT extent'
            Old = "createType=`"fullDevice`"`r`nRW 10 FLAT `"\\.\PhysicalDrive1`" 0{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'the size of a ZERO extent'
            Old = "createType=`"partitionedDevice`"`r`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`r`nRW 8 ZERO{0}`r`n"
            New = "createType=`"partitionedDevice`"`r`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`r`nRW 7 ZERO`r`n"
        }
        @{ Case = 'the access mode'
            Old = "createType=`"fullDevice`"`r`nRDONLY 9 FLAT `"\\.\PhysicalDrive1`" 0{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'the offset'
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 7{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'the createType value'
            Old = "createType=`"partitionedDevice`"{0}`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'the number of extents'
            Old = "createType=`"fullDevice`"`r`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`r`nRW 7 ZERO{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 2 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'blanks before an extent line'
            Old = "createType=`"fullDevice`"`r`n RW 9 FLAT `"\\.\PhysicalDrive1`" 0{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'blanks inside an extent line'
            Old = "createType=`"fullDevice`"`r`nRW  9 FLAT `"\\.\PhysicalDrive1`" 0{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'the line ending'
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0{0}`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"
        }
        @{ Case = 'blanks at the end of a line the launcher does not rewrite'
            Old = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n# end{0}`r`n"
            New = "createType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n# end`r`n"
        }
    ) {
        foreach ($blank in @(' ', "`t", " `t ")) {
            Test-PvmSameDescriptorText -Old ($Old -f $blank) -New $New | Should -BeFalse -Because "the line ends with [$blank]"
        }
        if ($Case -ne 'blanks at the end of a line the launcher does not rewrite') {
            Test-PvmSameDescriptorText -Old ($Old -f '') -New $New | Should -BeFalse -Because 'no blank ends the line'
        }
    }

    Context 'on disk' -Tag 'WindowsOnly' {
        BeforeEach {
            Mock -ModuleName PortableVM Write-Host {}
            $script:descriptor = Join-Path $TestDrive 'descriptor\stick.vmdk'
            $script:backup = Join-Path $TestDrive 'descriptor\backups\VMware\stick.vmdk.orig'
            $script:previous = Join-Path $TestDrive 'descriptor\backups\VMware\stick.vmdk.previous.orig'
            $script:log = Join-Path $TestDrive 'descriptor\launcher.log'
            if (Test-Path -LiteralPath $script:descriptor) { [IO.File]::SetAttributes($script:descriptor, 'Normal') }
            Write-TestFile -Path $script:descriptor -Text (Get-TestDescriptorText)
            Remove-Item -LiteralPath (Join-Path $TestDrive 'descriptor\backups') -Recurse -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "$script:descriptor.orig", "$script:descriptor.pvm-tmp", "$script:descriptor.pvm-old", $script:log, (Join-Path $TestDrive 'descriptor\new.vmdk') -ErrorAction SilentlyContinue
            $script:layout = @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive3" 0') }
            $script:latin1 = [Text.Encoding]::GetEncoding(28591)
            $script:copies = @{ BackupPath = $script:backup; PreviousPath = $script:previous; LogPath = $script:log }
        }

        It 'are rewritten byte for byte, with the first version and the version before the latest rewrite kept, disarmed' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly ((Get-TestDescriptorText).Replace('PhysicalDrive1', 'PhysicalDrive3'))
            $disarmed = (Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', '\\.\PortableVM-disarmed')
            [IO.File]::ReadAllText($script:backup) | Should -BeExactly $disarmed
            [IO.File]::ReadAllText($script:previous) | Should -BeExactly $disarmed
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0')

            # A change made between two rewrites is in the version before the latest one, not in the first.
            [IO.File]::AppendAllText($script:descriptor, "ddb.comment = `"edited`"`r`n")
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive4" 0') } @script:copies
            [IO.File]::ReadAllText($script:backup) | Should -BeExactly $disarmed
            [IO.File]::ReadAllText($script:previous) | Should -BeExactly ($disarmed + "ddb.comment = `"edited`"`r`n")
            @(Get-ChildItem -LiteralPath (Split-Path $script:descriptor) -Force -Name) | Should -BeExactly @('backups', 'launcher.log', 'stick.vmdk')
        }

        It 'keep every byte that does not change, a windows-1252 one and a byte order mark too' {
            $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $script:latin1.GetBytes("# caf$([char]0xE9)`r`ncreateType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n"))
            [IO.File]::WriteAllBytes($script:descriptor, $bytes)
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 9 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            $expected = [byte[]](@(0xEF, 0xBB, 0xBF) + $script:latin1.GetBytes("# caf$([char]0xE9)`r`ncreateType=`"fullDevice`"`r`nRW 9 FLAT `"\\.\PhysicalDrive3`" 0`r`n"))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor)) | Should -BeExactly ([Convert]::ToBase64String($expected))
        }

        It 'are left alone when they already point at the stick' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive1" 0') } @script:copies
            $script:backup | Should -Not -Exist
            $script:previous | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk already points at the stick')
        }

        It 'are left alone, byte for byte, when they point at the stick and differ only in <Case>' -ForEach @(
            @{ Case = "VMware's blank at the end of the extent line"; Find = 'PhysicalDrive1" 0'; Replace = 'PhysicalDrive1" 0 '; Layout = @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive1" 0') } }
            @{ Case = 'a tab at the end of the createType line'; Find = 'createType="fullDevice"'; Replace = "createType=`"fullDevice`"`t"; Layout = @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive1" 0') } }
            @{ Case = 'a blank at the end of a ZERO extent line'
                Find = "createType=`"fullDevice`"`r`n`r`n# Extent description`r`nRW 3900000 FLAT `"\\.\PhysicalDrive1`" 0"
                Replace = "createType=`"partitionedDevice`"`r`n`r`n# Extent description`r`nRW 2500000 FLAT `"\\.\PhysicalDrive1`" 0`r`nRW 1400000 ZERO "
                Layout = @{ CreateType = 'partitionedDevice'; Extents = @('RW 2500000 FLAT "\\.\PhysicalDrive1" 0', 'RW 1400000 ZERO') }
            }
        ) {
            $text = (Get-TestDescriptorText).Replace($Find, $Replace)
            $text | Should -Not -BeExactly (Get-TestDescriptorText)
            Write-TestFile -Path $script:descriptor -Text $text
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor))
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $Layout @script:copies -WhatIf
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $Layout @script:copies
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor)) | Should -BeExactly $before
            $script:backup | Should -Not -Exist
            $script:previous | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk already points at the stick', 'stick.vmdk already points at the stick')
        }

        It 'are rewritten byte for byte as before when a real change comes with a blank at the end of the extent line' {
            $old = (Get-TestDescriptorText).Replace('PhysicalDrive1" 0', 'PhysicalDrive1" 0 ')
            Write-TestFile -Path $script:descriptor -Text $old
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies
            $expected = $script:latin1.GetBytes((Get-TestDescriptorText).Replace('PhysicalDrive1', 'PhysicalDrive3'))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor)) | Should -BeExactly ([Convert]::ToBase64String($expected))
            $disarmed = $script:latin1.GetBytes($old.Replace('\\.\PhysicalDrive1', '\\.\PortableVM-disarmed'))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:backup)) | Should -BeExactly ([Convert]::ToBase64String($disarmed))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous)) | Should -BeExactly ([Convert]::ToBase64String($disarmed))
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0')
        }

        It 'are only logged under -WhatIf' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies -WhatIf
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly (Get-TestDescriptorText)
            $script:backup | Should -Not -Exist
            $script:previous | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0')
        }

        It 'stop the launcher when they hold no extent' {
            Write-TestFile -Path $script:descriptor -Text 'createType="fullDevice"'
            $message = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $message | Should -BeExactly "Unexpected content in $script:descriptor - no disk extent found. Nothing was started."
        }

        It 'stop the launcher, changing nothing, at <Case>' -ForEach @(
            @{ Case = 'a sparse extent'; Setup = { Write-TestFile -Path $script:descriptor -Text "createType=`"monolithicSparse`"`nRW 17 SPARSE `"disk.vmdk`"" }
                Message = 'Unexpected content in {0} - line 2 has a SPARSE extent, and the launcher rewrites only FLAT and ZERO extents. Nothing was started.'
            }
            @{ Case = 'a disk image'; Setup = { [IO.File]::WriteAllBytes($script:descriptor, [byte[]][char[]]'KDMV....') }
                Message = 'Unexpected content in {0} - it is a disk image, not a descriptor. Nothing was started.'
            }
            @{ Case = 'a read-only descriptor'; Setup = { [IO.File]::SetAttributes($script:descriptor, 'ReadOnly') }
                Message = '{0} is read-only, so the launcher does not rewrite it. Clear that attribute, then start again. Nothing was started.'
            }
            @{ Case = 'a cut-off write of it'; Setup = { [IO.File]::WriteAllText("$script:descriptor.pvm-tmp", 'x') }
                Message = 'A write of {0} did not finish. To set it right, remove stick.vmdk.pvm-tmp; stick.vmdk itself is whole. Nothing was started.'
            }
            @{ Case = 'a cut-off write of a copy'; Setup = { $null = [IO.Directory]::CreateDirectory((Split-Path $script:previous)); [IO.File]::WriteAllText("$script:previous.pvm-tmp", 'x') }
                Message = 'A write of {1} did not finish. To set it right, remove stick.vmdk.previous.orig.pvm-tmp, which may be incomplete. Nothing was started.'
            }
        ) {
            & $Setup
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor))
            $message = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $message | Should -BeExactly ($Message -f $script:descriptor, $script:previous)
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor)) | Should -BeExactly $before
            $script:backup | Should -Not -Exist
        }

        It 'stop the launcher when the rewrite fails, naming the cause, with the file unchanged and the details logged' {
            Mock -ModuleName PortableVM Switch-PvmFile { throw [IO.IOException]::new('The process cannot access the file because it is being used by another process.', [int]0x80070020) }
            $thrown = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies } catch { $_ }
            Get-PvmStopMessage -ErrorRecord $thrown | Should -BeExactly "The launcher could not rewrite $script:descriptor, because it is open in another program; the file is unchanged. Nothing was started."
            Get-PvmStopDetail -ErrorRecord $thrown | Should -BeLike '*being used by another process*'
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly (Get-TestDescriptorText)
            @(Get-ChildItem -LiteralPath (Split-Path $script:descriptor) -Force -Name -Filter 'stick.vmdk*') | Should -BeExactly @('stick.vmdk')
        }

        It 'stop the launcher with the step that puts the version before back when the rewrite does not read back from its place' {
            Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Replace($Temp, $Path, $Old); [IO.File]::AppendAllText($Path, 'changed') }
            $thrown = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies } catch { $_ }
            Get-PvmStopMessage -ErrorRecord $thrown | Should -BeExactly ("A write of $script:descriptor did not finish. To set it right, remove stick.vmdk, then rename stick.vmdk.pvm-old back to stick.vmdk, " +
                'which holds the version before the write. Nothing was started.')
            Get-PvmStopDetail -ErrorRecord $thrown | Should -BeLike "$script:descriptor did not read back as written after it took the file's place.*"
            [IO.File]::ReadAllText("$script:descriptor.pvm-old") | Should -BeExactly (Get-TestDescriptorText)
        }

        It 'stop the launcher at a descriptor that another program changed after it was read, and leave that program''s version' {
            $change = Get-PvmDescriptorChange -Path $script:descriptor -Layout $script:layout @script:copies
            Write-TestFile -Path $script:descriptor -Text 'written by another program'
            $message = try { Save-PvmFileChange -Change $change -LogPath $script:log } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $message | Should -BeExactly ("The launcher could not rewrite $script:descriptor, because another program changed it after the launcher read it; " +
                'the launcher left it as that program wrote it. Close that program, then start again. Nothing was started.')
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly 'written by another program'
        }

        It 'keep the copy of the version before the latest rewrite as it was when a later rewrite fails' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3800000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            $kept = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous))
            # Only the descriptor's own swap fails; the copy's goes through.
            Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Replace($Temp, $Path, $Old) }
            Mock -ModuleName PortableVM Switch-PvmFile { throw [IO.IOException]::new('The process cannot access the file because it is being used by another process.', [int]0x80070020) } -ParameterFilter {
                $Path -eq $script:descriptor
            }
            $message = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3700000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $message | Should -BeExactly "The launcher could not rewrite $script:descriptor, because it is open in another program; the file is unchanged. Nothing was started."
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous)) | Should -BeExactly $kept
            @(Get-ChildItem -LiteralPath (Split-Path $script:previous) -Force -Name | Sort-Object) | Should -BeExactly @('stick.vmdk.orig', 'stick.vmdk.previous.orig')
        }

        It 'stop the launcher, with the step that puts the version before back, when the old version cannot be removed after the rewrite' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3800000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            $kept = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous))
            Mock -ModuleName PortableVM Invoke-PvmSleep {}
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($Path) }
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) } -ParameterFilter { $Path -eq "$script:descriptor.pvm-old" }
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3700000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly ("A write of $script:descriptor did not finish. To set it right, remove stick.vmdk, then rename stick.vmdk.pvm-old back to stick.vmdk, " +
                'which holds the version before the write. Nothing was started.')
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous)) | Should -BeExactly $kept
        }

        It 'stop the launcher before the rewrite, with the step for the copy, when the copy''s own old version cannot be removed' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3800000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor))
            Mock -ModuleName PortableVM Invoke-PvmSleep {}
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($Path) }
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) } -ParameterFilter { $Path -eq "$script:previous.pvm-old" }
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3700000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly ("A write of $script:previous did not finish. To set it right, remove stick.vmdk.previous.orig, then rename stick.vmdk.previous.orig.pvm-old back to " +
                'stick.vmdk.previous.orig, which holds the version before the write. Nothing was started.')
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor)) | Should -BeExactly $before
        }

        It 'name, after the file''s step, the step that keeps the copy put back when its old version could not be removed either' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3800000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            $kept = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous))
            Mock -ModuleName PortableVM Invoke-PvmSleep {}
            $script:held = $false
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($Path) }
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { $script:held = $true; throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) } -ParameterFilter {
                $Path -eq "$script:descriptor.pvm-old"
            }
            # The copy's own old version goes at the copy's write, but not after the copy is put back.
            Mock -ModuleName PortableVM Remove-PvmWriteCopy {
                if ($script:held) { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) }
                [IO.File]::Delete($Path)
            } -ParameterFilter { $Path -eq "$script:previous.pvm-old" }
            $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 3700000 FLAT "\\.\PhysicalDrive3" 0') }
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $layout @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeLike "A write of $script:descriptor did not finish.*"
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:previous)) | Should -BeExactly $kept
            # The owner takes the file's step.
            [IO.File]::Delete($script:descriptor)
            [IO.File]::Move("$script:descriptor.pvm-old", $script:descriptor)
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $layout @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly ("A write of $script:previous did not finish. To set it right, remove stick.vmdk.previous.orig.pvm-old, which holds a copy of the file " +
                'as it is now; stick.vmdk.previous.orig itself is whole. Nothing was started.')
        }

        It 'stop the launcher, naming both, when the old version cannot be removed and the file is gone too' {
            Mock -ModuleName PortableVM Invoke-PvmSleep {}
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($Path) }
            # As when the stick is pulled during the tries.
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($script:descriptor); [IO.File]::Delete($Path); throw [IO.IOException]::new('The device is not ready.', [int]0x80070015) } -ParameterFilter {
                $Path -eq "$script:descriptor.pvm-old"
            }
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly "The launcher could not remove $script:descriptor.pvm-old after it rewrote $script:descriptor. Check both, then start again. Nothing was started."
        }

        It 'stop the launcher with the cause when the file cannot be read any more after it was prepared' {
            $change = Get-PvmDescriptorChange -Path $script:descriptor -Layout $script:layout @script:copies
            $held = [IO.File]::Open($script:descriptor, 'Open', 'Read', 'None')
            try { $stop = try { Save-PvmFileChange -Change $change -LogPath $script:log } catch { Get-PvmStopMessage -ErrorRecord $_ } }
            finally { $held.Dispose() }
            $stop | Should -BeExactly ("The launcher could not rewrite $script:descriptor, because it is open in another program; check the file against its copies " +
                'below LauncherData\backups. Nothing was started.')
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly (Get-TestDescriptorText)
        }

        It 'stop the launcher, naming the first copy, when it cannot be written' {
            $null = [IO.Directory]::CreateDirectory($script:backup)
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly "The launcher could not write the copy $script:backup, because an item of that name is in the way, so it did not rewrite $script:descriptor. Nothing was started."
        }

        It 'stop the launcher, a dry run too, at a read-only copy of the version before the latest rewrite, naming that copy' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3800000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            [IO.File]::SetAttributes($script:previous, 'ReadOnly')
            try {
                foreach ($whatIf in $true, $false) {
                    $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3700000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies -WhatIf:$whatIf } catch { Get-PvmStopMessage -ErrorRecord $_ }
                    $stop | Should -BeExactly "$script:previous is read-only, so the launcher does not rewrite it. Clear that attribute, then start again. Nothing was started."
                }
            } finally {
                [IO.File]::SetAttributes($script:previous, 'Normal')
            }
        }

        It 'stop the launcher, naming the copy, when a copy cannot be written, and leave the file as it was' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3800000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies
            $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor))
            Mock -ModuleName PortableVM Switch-PvmFile { [IO.File]::Replace($Temp, $Path, $Old) }
            Mock -ModuleName PortableVM Switch-PvmFile { throw [IO.IOException]::new('The process cannot access the file because it is being used by another process.', [int]0x80070020) } -ParameterFilter {
                $Path -eq $script:previous
            }
            $stop = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3700000 FLAT "\\.\PhysicalDrive3" 0') } @script:copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly "The launcher could not write the copy $script:previous, because it is open in another program, so it did not rewrite $script:descriptor. Nothing was started."
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:descriptor)) | Should -BeExactly $before
        }

        It 'stop the launcher with the cause or the step also when the path holds braces: <Case>' -ForEach @(
            @{ Case = 'a failed swap'; Swap = { throw [IO.IOException]::new('The process cannot access the file because it is being used by another process.', [int]0x80070020) }
                Message = 'The launcher could not rewrite <path>, because it is open in another program; the file is unchanged. Nothing was started.'
            }
            @{ Case = 'a swap that left the file missing'; Swap = { [IO.File]::Move($Path, $Old); throw [IO.IOException]::new('Unable to move the replacement file.', [int]0x80070499) }
                Message = 'A write of <path> did not finish. To set it right, rename stick.vmdk.pvm-old back to stick.vmdk and remove stick.vmdk.pvm-tmp. Nothing was started.'
            }
        ) {
            $folder = Join-Path $TestDrive "braces {$([guid]::NewGuid().ToString('N').Substring(0, 8))}"
            $path = Join-Path $folder 'stick.vmdk'
            Write-TestFile -Path $path -Text (Get-TestDescriptorText)
            Mock -ModuleName PortableVM Switch-PvmFile $Swap
            $copies = @{ BackupPath = (Join-Path $folder 'backups\stick.vmdk.orig'); PreviousPath = (Join-Path $folder 'backups\stick.vmdk.previous.orig'); LogPath = $script:log }
            # Not $message: variable names ignore case, so it would be the row's Message.
            $stop = try { Set-PvmDiskDescriptor -Path $path -Layout $script:layout @copies } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $stop | Should -BeExactly $Message.Replace('<path>', $path)
        }

        It 'are not created in a missing folder, which the stop names as the cause, under -WhatIf too' {
            $new = Join-Path $TestDrive 'descriptor\missing\new.vmdk'
            foreach ($whatIf in $true, $false) {
                $message = try { New-PvmVMwareDescriptor -Path $new -Layout $script:layout -LogPath $script:log -WhatIf:$whatIf } catch { Get-PvmStopMessage -ErrorRecord $_ }
                $message | Should -BeExactly "The launcher could not create $new, because its folder is missing. Nothing was started."
            }
            Split-Path $new | Should -Not -Exist
        }

        It 'are created for VMware as ASCII without a BOM, but not under -WhatIf' {
            $new = Join-Path $TestDrive 'descriptor\new.vmdk'
            New-PvmVMwareDescriptor -Path $new -Layout $script:layout -LogPath $script:log -WhatIf
            $new | Should -Not -Exist
            New-PvmVMwareDescriptor -Path $new -Layout $script:layout -LogPath $script:log
            $bytes = [IO.File]::ReadAllBytes($new)
            $bytes | Should -Be ([Text.Encoding]::ASCII.GetBytes((Get-PvmVMwareDescriptorText -Layout $script:layout)))
            Get-TestLog -Path $script:log | Should -BeExactly @('Creating new.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0', 'Creating new.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0')
        }
    }
}

Describe 'Backups of rewritten files' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive 'copies'
        Remove-Item -LiteralPath $script:folder -Recurse -Force -ErrorAction SilentlyContinue
        $script:first = Join-Path $script:folder 'backups\VMware\stick.vmdk.orig'
        $script:previous = Join-Path $script:folder 'backups\VMware\stick.vmdk.previous.orig'
        $script:latin1 = [Text.Encoding]::GetEncoding(28591)
        $script:one = $script:latin1.GetBytes("RW 9 FLAT `"\\.\PhysicalDrive1`" 0`r`n")
        $script:two = $script:latin1.GetBytes("RW 9 FLAT `"\\.\PhysicalDrive2`" 0`r`n")
        $script:disarmed = $script:latin1.GetBytes("RW 9 FLAT `"\\.\PortableVM-disarmed`" 0`r`n")
    }

    It 'keep the first version once, disarmed, creating its folder, and never replace it' {
        Save-PvmFirstCopy -Bytes $script:one -BackupPath $script:first -Disarm
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:first)) -Right $script:disarmed | Should -BeTrue
        Save-PvmFirstCopy -Bytes ([Text.Encoding]::ASCII.GetBytes('other')) -BackupPath $script:first -Disarm
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:first)) -Right $script:disarmed | Should -BeTrue
    }

    It 'keep the version before the latest rewrite, replaced at each rewrite' {
        Save-PvmPreviousCopy -Bytes $script:one -BackupPath $script:previous
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:previous)) -Right $script:one | Should -BeTrue
        Save-PvmPreviousCopy -Bytes $script:two -BackupPath $script:previous
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:previous)) -Right $script:two | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path $script:previous) -Force -Name) | Should -BeExactly @('stick.vmdk.previous.orig')
    }

    It 'leave the previous version alone when it holds the bytes already, and disarm a descriptor''s' {
        Save-PvmPreviousCopy -Bytes $script:one -BackupPath $script:previous -Disarm
        $written = [IO.File]::GetLastWriteTimeUtc($script:previous)
        [IO.File]::SetLastWriteTimeUtc($script:previous, $written.AddDays(-1))
        Save-PvmPreviousCopy -Bytes $script:two -BackupPath $script:previous -Disarm
        Test-PvmSameContent -Left ([IO.File]::ReadAllBytes($script:previous)) -Right $script:disarmed | Should -BeTrue
        [IO.File]::GetLastWriteTimeUtc($script:previous) | Should -Be $written.AddDays(-1)
    }
}

Describe 'Drive letters' {
    It 'move every quoted path below the root to the new letter, for both separators' {
        $text = '<a src="Q:\Portable\Stick\VirtualBox\x.vbox"/><b location="Q:/Portable/Stick/VirtualBox/x.vmdk"/><c path="Q:\Other\x"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\Portable\Stick' -Letter 'E' |
            Should -BeExactly '<a src="E:\Portable\Stick\VirtualBox\x.vbox"/><b location="E:/Portable/Stick/VirtualBox/x.vmdk"/><c path="Q:\Other\x"/>'
    }

    It 'move, at a drive root, only the paths on the stick''s old letter, which the paths to the VM''s own files show' {
        $text = '<a src="Q:\VirtualBox\x.vbox"/><b src="C:\ISOs\y.iso"/><c src="q:/Other/z"/><d src="C:\VirtualBox\g.iso"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\' -Letter 'E' -Known 'D:\virtualbox\X.vbox' |
            Should -BeExactly '<a src="E:\VirtualBox\x.vbox"/><b src="C:\ISOs\y.iso"/><c src="E:/Other/z"/><d src="C:\VirtualBox\g.iso"/>'
    }

    It 'move nothing at a drive root when no path to the VM''s own files shows the old letter' {
        $text = '<a src="Q:\VirtualBox\x.vbox"/><b location="disk.vmdk"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\' -Letter 'E' -Known 'D:\VirtualBox\Test VM\disk.vmdk' | Should -BeExactly $text
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\' -Letter 'E' | Should -BeExactly $text
    }

    It 'match the folders in any case and keep their spelling' {
        ConvertTo-PvmDriveLetterText -Text '<a src="Q:\portable\stick\x.vbox"/>' -Root 'D:\Portable\Stick' -Letter 'E' | Should -BeExactly '<a src="E:\portable\stick\x.vbox"/>'
    }

    It 'take a $ in a folder name literally, and match an & only as XML writes it' {
        ConvertTo-PvmDriveLetterText -Text '<a src="Q:\A$&amp;B\x"/>' -Root 'D:\A$&B' -Letter 'E' | Should -BeExactly '<a src="E:\A$&amp;B\x"/>'
        # A folder named x&amp;y is written as x&amp;amp;y, so a host folder x&y stays.
        $text = '<a src="Q:\x&amp;y\host.iso"/><b src="Q:\x&amp;amp;y\stick.vmdk"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\x&amp;y' -Letter 'E' | Should -BeExactly '<a src="Q:\x&amp;y\host.iso"/><b src="E:\x&amp;amp;y\stick.vmdk"/>'
    }

    It 'learn the old letter at a drive root from a path to the VM''s own files with an &, as XML writes it' {
        $text = '<MachineEntry src="G:\VMs &amp; Co\VM.vbox"/><Image location="G:\ISOs\a.iso"/><Image location="C:\ISOs\b.iso"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'E:\' -Letter 'F' -Known 'E:\VMs & Co\VM.vbox' |
            Should -BeExactly '<MachineEntry src="F:\VMs &amp; Co\VM.vbox"/><Image location="F:\ISOs\a.iso"/><Image location="C:\ISOs\b.iso"/>'
    }

    It 'leave a folder whose name only starts like the stick folder' {
        $text = '<a src="Q:\Portable\StickOld\x"/><b src="Q:\Portable\Stick"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\Portable\Stick' -Letter 'E' | Should -BeExactly $text
    }

    Context 'in a file' -Tag 'WindowsOnly' {
        BeforeEach {
            Mock -ModuleName PortableVM Write-Host {}
            $script:file = Join-Path $TestDrive 'letters\VirtualBox.xml'
            $script:backup = Join-Path $TestDrive 'letters\backups\VirtualBox\VirtualBox.xml.launcher-backup'
            $script:previous = Join-Path $TestDrive 'letters\backups\VirtualBox\VirtualBox.xml.previous.launcher-backup'
            $script:log = Join-Path $TestDrive 'letters\launcher.log'
            Write-TestFile -Path $script:file -Text '<e src="Q:\Portable\Stick\x.vbox"/>'
            Remove-Item -LiteralPath (Join-Path $TestDrive 'letters\backups') -Recurse -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:log -ErrorAction SilentlyContinue
            $script:change = @{ Path = $script:file; Root = 'D:\Portable\Stick'; BackupPath = $script:backup; PreviousPath = $script:previous; LogPath = $script:log }
        }

        It 'are rewritten, with copies of the first version and of the version before the latest rewrite' {
            Set-PvmDriveLetterInFile @script:change -Letter 'E'
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="E:\Portable\Stick\x.vbox"/>'
            Set-PvmDriveLetterInFile @script:change -Letter 'F'
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="F:\Portable\Stick\x.vbox"/>'
            [IO.File]::ReadAllText($script:backup) | Should -BeExactly '<e src="Q:\Portable\Stick\x.vbox"/>'
            [IO.File]::ReadAllText($script:previous) | Should -BeExactly '<e src="E:\Portable\Stick\x.vbox"/>'
            "$script:file.launcher-backup" | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('VirtualBox.xml: paths moved to drive E:', 'VirtualBox.xml: paths moved to drive F:')
        }

        It 'keep a byte order mark and every byte but the letter' {
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes("<e src=`"Q:\Portable\Stick\caf$([char]0xE9).vbox`"/>`r`n"))
            [IO.File]::WriteAllBytes($script:file, $bytes)
            Set-PvmDriveLetterInFile @script:change -Letter 'E'
            $expected = [byte[]](@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes("<e src=`"E:\Portable\Stick\caf$([char]0xE9).vbox`"/>`r`n"))
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:file)) | Should -BeExactly ([Convert]::ToBase64String($expected))
        }

        It 'stop the launcher, changing nothing, at <Case>' -ForEach @(
            @{ Case = 'a read-only file'; Setup = { [IO.File]::SetAttributes($script:file, 'ReadOnly') }
                Message = '<file> is read-only, so the launcher does not rewrite it. Clear that attribute, then start again. Nothing was started.'
            }
            @{ Case = 'a write of its copy that did not finish'; Setup = { $null = [IO.Directory]::CreateDirectory((Split-Path $script:previous)); [IO.File]::WriteAllText("$script:previous.pvm-tmp", 'x') }
                Message = 'A write of <copy> did not finish. To set it right, remove VirtualBox.xml.previous.launcher-backup.pvm-tmp, which may be incomplete. Nothing was started.'
            }
            @{ Case = 'a read-only copy of the version before the latest rewrite'; Setup = {
                    Write-TestFile -Path $script:previous -Text '<e src="P:\Portable\Stick\x.vbox"/>'
                    [IO.File]::SetAttributes($script:previous, 'ReadOnly')
                }
                Message = '<copy> is read-only, so the launcher does not rewrite it. Clear that attribute, then start again. Nothing was started.'
            }
        ) {
            & $Setup
            try {
                $before = [IO.File]::ReadAllText($script:file)
                foreach ($whatIf in $true, $false) {
                    $stop = try { Set-PvmDriveLetterInFile @script:change -Letter 'E' -WhatIf:$whatIf } catch { Get-PvmStopMessage -ErrorRecord $_ }
                    $stop | Should -BeExactly $Message.Replace('<file>', $script:file).Replace('<copy>', $script:previous)
                }
                [IO.File]::ReadAllText($script:file) | Should -BeExactly $before
            } finally {
                [IO.File]::SetAttributes($script:file, 'Normal')
                if ([IO.File]::Exists($script:previous)) { [IO.File]::SetAttributes($script:previous, 'Normal') }
                Remove-Item -LiteralPath "$script:previous.pvm-tmp" -ErrorAction SilentlyContinue
            }
        }

        It 'stop the launcher at a file that is not UTF-8, and change nothing' {
            $bytes = [byte[]]([Text.Encoding]::ASCII.GetBytes('<e src="Q:\Portable\Stick\caf') + @(0xE9) + [Text.Encoding]::ASCII.GetBytes('.vbox"/>'))
            [IO.File]::WriteAllBytes($script:file, $bytes)
            $message = try { Set-PvmDriveLetterInFile @script:change -Letter 'E' } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $message | Should -BeExactly "$script:file is not UTF-8 text, as VirtualBox writes it, so the launcher does not change its drive letters. Nothing was started."
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:file)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
        }

        It 'move the stick''s old letter at a drive root, which a path to the VM''s own file shows' {
            Write-TestFile -Path $script:file -Text '<e src="Q:\VirtualBox\x.vbox"/><f src="C:\ISOs\y.iso"/>'
            Set-PvmDriveLetterInFile -Path $script:file -Root 'D:\' -Known 'D:\VirtualBox\x.vbox' -BackupPath $script:backup -PreviousPath $script:previous -LogPath $script:log -Letter 'E'
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="E:\VirtualBox\x.vbox"/><f src="C:\ISOs\y.iso"/>'
        }

        It 'are left alone when the letter already fits, also in another case' {
            Set-PvmDriveLetterInFile @script:change -Letter 'q'
            $script:backup | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('VirtualBox.xml: drive letter OK')
        }

        It 'are only logged under -WhatIf' {
            Set-PvmDriveLetterInFile @script:change -Letter 'E' -WhatIf
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="Q:\Portable\Stick\x.vbox"/>'
            $script:backup | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('VirtualBox.xml: paths moved to drive E:')
        }
    }
}

Describe 'Running VMs' {
    # -ForEach data is built before BeforeAll runs, so it spells the UUID out.
    It 'count a VirtualBox process as this VM when <Case>' -ForEach @(
        @{ Case = 'its command line names the UUID'; CommandLine = 'VirtualBoxVM.exe --startvm 5ca1ab1e-0000-4000-8000-000000000001'; Expected = $true }
        @{ Case = 'it names the UUID in braces and upper case'; CommandLine = 'VirtualBoxVM.exe --startvm {5CA1AB1E-0000-4000-8000-000000000001}'; Expected = $true }
        @{ Case = 'the UUID is in a comment beside another GUID'; CommandLine = 'VirtualBoxVM.exe --comment "copy of 5ca1ab1e-0000-4000-8000-000000000001" --startvm 5ca1ab1e-0000-4000-8000-000000000009'; Expected = $true }
        @{ Case = 'its command line cannot be read'; CommandLine = $null; Expected = $true }
        @{ Case = 'it names another VM, which it is not'; CommandLine = 'VirtualBoxVM.exe --startvm 5ca1ab1e-0000-4000-8000-000000000009'; Expected = $false }
        @{ Case = 'it holds the UUID only as part of a longer value, which it is not'; CommandLine = 'VirtualBoxVM.exe --startvm 15ca1ab1e-0000-4000-8000-0000000000012'; Expected = $false }
    ) {
        Test-PvmVirtualBoxVmProcess -Process ([pscustomobject]@{ CommandLine = $CommandLine }) -VmUuid '5ca1ab1e-0000-4000-8000-000000000001' | Should -Be $Expected
    }

    It 'find a VM in the VirtualBox list only by the UUID in braces at the end of its line: <Case>' -ForEach @(
        @{ Case = 'listed'; Output = "`"Other`" {5ca1ab1e-0000-4000-8000-000000000009}`r`n`"Test VM`" {5CA1AB1E-0000-4000-8000-000000000001}`r`n"; Expected = $true }
        @{ Case = 'only in another VM''s name'; Output = "`"Copy of {5ca1ab1e-0000-4000-8000-000000000001}`" {5ca1ab1e-0000-4000-8000-000000000009}"; Expected = $false }
        @{ Case = 'not listed'; Output = "`"Other`" {5ca1ab1e-0000-4000-8000-000000000009}"; Expected = $false }
        @{ Case = 'an empty list'; Output = ''; Expected = $false }
    ) {
        Test-PvmVirtualBoxVmListed -Output $Output -VmUuid '5ca1ab1e-0000-4000-8000-000000000001' | Should -Be $Expected
    }

    It 'count a VMware process as this VM when <Case>' -ForEach @(
        @{ Case = 'its command line names the .vmx in another case'; CommandLine = '"vmware-vmx.exe" -s x "D:\VMWARE\TEST VM.VMX"'; Expected = $true }
        @{ Case = 'its command line cannot be read'; CommandLine = $null; Expected = $true }
        @{ Case = 'it runs another .vmx, which it is not'; CommandLine = '"vmware-vmx.exe" "D:\VMware\Other.vmx"'; Expected = $false }
    ) {
        Test-PvmVMwareVmProcess -Process ([pscustomobject]@{ CommandLine = $CommandLine }) -Vmx 'D:\VMware\Test VM.vmx' | Should -Be $Expected
    }
}

Describe 'Saved states' {
    It 'read the .vmx settings: the last of two values counts, quotes are optional, comments are skipped' {
        $values = ConvertFrom-PvmVmxText -Text "Suspend.Disabled = `"FALSE`"`r`nsuspend.disabled=`"TRUE`" # set by hand`r`n# uuid.action = `"create`"`r`nuuid.action = keep # note`r`nno equals sign"
        $values['suspend.disabled'] | Should -BeExactly 'TRUE'
        $values['uuid.action'] | Should -BeExactly 'keep'
        $values.Count | Should -Be 2
    }

    It 'count a .vmx that cannot be read as unknown' {
        $path = Join-Path $TestDrive 'locked.vmx'
        Write-TestFile -Path $path -Text 'config.version = "8"'
        $lock = [IO.File]::Open($path, 'Open', 'Read', 'None')
        try { $state = Get-PvmVMwareState -Path $path } finally { $lock.Dispose() }
        $state.State | Should -BeExactly 'Unknown'
        $state.Reason | Should -BeLike 'the file cannot be read (*'
    }

    It 'are told from a .vmx: <Case>' -ForEach @(
        @{ Case = 'suspended'; Text = "config.version = `"8`"`r`ncheckpoint.vmState = `"Test VM.vmss`""; State = 'Saved' }
        @{ Case = 'resumed, with an empty checkpoint'; Text = "config.version = `"8`"`r`ncheckpoint.vmState = `"`""; State = 'NotSaved' }
        @{ Case = 'commented out'; Text = "config.version = `"8`"`r`n# checkpoint.vmState = `"Test VM.vmss`""; State = 'NotSaved' }
        @{ Case = 'never suspended'; Text = 'config.version = "8"'; State = 'NotSaved' }
        @{ Case = 'without config.version'; Text = 'checkpoint.vmState = "x.vmss"'; State = 'Unknown' }
        @{ Case = 'with checkpoint.vmState set twice'; Text = "config.version = `"8`"`r`ncheckpoint.vmState = `"x.vmss`"`r`ncheckpoint.vmState = `"`""; State = 'Unknown' }
        @{ Case = 'empty'; Text = ''; State = 'Unknown' }
    ) {
        $path = Join-Path $TestDrive 'state.vmx'
        Write-TestFile -Path $path -Text $Text
        (Get-PvmVMwareState -Path $path).State | Should -BeExactly $State
    }

    It 'are told from a .vbox: <Case>' -ForEach @(
        @{ Case = 'saved'; Text = '<VirtualBox xmlns="http://www.virtualbox.org/"><Machine uuid="{x}" stateFile="Snapshots\x.sav"/></VirtualBox>'; State = 'Saved' }
        @{ Case = 'not saved'; Text = '<VirtualBox xmlns="http://www.virtualbox.org/"><Machine uuid="{x}" stateFile=""/></VirtualBox>'; State = 'NotSaved' }
        @{ Case = 'saved only in a snapshot'; Text = '<VirtualBox xmlns="http://www.virtualbox.org/"><Machine uuid="{x}"><Snapshot stateFile="x.sav"/></Machine></VirtualBox>'; State = 'NotSaved' }
        @{ Case = 'no XML'; Text = '<VirtualBox><Machine'; State = 'Unknown' }
        @{ Case = 'without a Machine'; Text = '<VirtualBox xmlns="http://www.virtualbox.org/"/>'; State = 'Unknown' }
        @{ Case = 'with a DTD'; Text = '<!DOCTYPE x [<!ENTITY e "x">]><VirtualBox><Machine uuid="{x}"/></VirtualBox>'; State = 'Unknown' }
    ) {
        $path = Join-Path $TestDrive 'state.vbox'
        Write-TestFile -Path $path -Text $Text
        (Get-PvmVirtualBoxState -Path $path).State | Should -BeExactly $State
    }

    It 'count a missing file as unknown, saying so' {
        $vmware = Get-PvmVMwareState -Path (Join-Path $TestDrive 'missing.vmx')
        $vmware.State | Should -BeExactly 'Unknown'
        $vmware.Reason | Should -BeExactly 'the file does not exist'
        (Get-PvmVirtualBoxState -Path (Join-Path $TestDrive 'missing.vbox')).State | Should -BeExactly 'Unknown'
    }
}

Describe 'Hypervisor choice' {
    It 'picks <Expected> for setting "<Setting>", VMware <VMware>, VirtualBox <VirtualBox>, suspended <Suspended>, saved <Saved>, .vmx <Vmx>' -ForEach @(
        @{ Setting = 'VMware'; VMware = $false; VirtualBox = $true; Suspended = $false; Saved = $true; Vmx = $false; Expected = 'VMware' }
        @{ Setting = 'vmware'; VMware = $false; VirtualBox = $true; Suspended = $false; Saved = $true; Vmx = $false; Expected = 'VMware' }
        @{ Setting = 'VirtualBox'; VMware = $true; VirtualBox = $false; Suspended = $true; Saved = $false; Vmx = $true; Expected = 'VirtualBox' }
        @{ Setting = 'Auto'; VMware = $true; VirtualBox = $true; Suspended = $true; Saved = $true; Vmx = $true; Expected = 'VMware' }
        @{ Setting = 'Auto'; VMware = $false; VirtualBox = $true; Suspended = $true; Saved = $true; Vmx = $true; Expected = 'VirtualBox' }
        @{ Setting = 'Auto'; VMware = $true; VirtualBox = $true; Suspended = $false; Saved = $true; Vmx = $true; Expected = 'VirtualBox' }
        @{ Setting = 'Auto'; VMware = $true; VirtualBox = $false; Suspended = $false; Saved = $true; Vmx = $true; Expected = 'VMware' }
        @{ Setting = 'Auto'; VMware = $true; VirtualBox = $true; Suspended = $false; Saved = $false; Vmx = $true; Expected = 'VMware' }
        @{ Setting = 'Auto'; VMware = $true; VirtualBox = $true; Suspended = $false; Saved = $false; Vmx = $false; Expected = 'VirtualBox' }
        @{ Setting = 'Auto'; VMware = $false; VirtualBox = $false; Suspended = $false; Saved = $false; Vmx = $false; Expected = 'VirtualBox' }
        @{ Setting = 'VBox'; VMware = $true; VirtualBox = $true; Suspended = $false; Saved = $false; Vmx = $true; Expected = 'VMware' }
        @{ Setting = ''; VMware = $true; VirtualBox = $true; Suspended = $false; Saved = $false; Vmx = $true; Expected = 'VMware' }
    ) {
        $choice = @{
            Setting = $Setting; VMwareInstalled = $VMware; VirtualBoxInstalled = $VirtualBox
            VMwareSuspended = $Suspended; VirtualBoxSaved = $Saved; VMwareVmxExists = $Vmx
        }
        Select-PvmHypervisor @choice | Should -BeExactly $Expected
    }

    It 'finds VMware Workstation in the 32-bit key first, then the native one, and only with vmware.exe' {
        $folder = Join-Path $TestDrive 'programs\vmware'
        Write-TestFile -Path (Join-Path $folder 'vmware.exe') -Text ''
        Mock -ModuleName PortableVM Invoke-PvmGetRegistryValue { Join-Path $TestDrive 'programs\none' } -ParameterFilter { $Path -like '*WOW6432Node*' }
        Mock -ModuleName PortableVM Invoke-PvmGetRegistryValue { Join-Path $TestDrive 'programs\vmware' } -ParameterFilter { $Path -notlike '*WOW6432Node*' }
        Get-PvmVMwareDir | Should -BeExactly $folder
        Should -Invoke -CommandName Invoke-PvmGetRegistryValue -ModuleName PortableVM -Times 2 -Exactly
    }

    It 'finds no VirtualBox without VBoxManage.exe in its folder' {
        Mock -ModuleName PortableVM Invoke-PvmGetRegistryValue { Join-Path $TestDrive 'programs\none' }
        Get-PvmVirtualBoxDir | Should -BeNullOrEmpty
    }

    It 'reads the VirtualBox VM state from showvminfo' {
        Get-PvmVirtualBoxVmState -Output "name=`"x`"`nVMState=`"saved`"`nVMStateChangeTime=`"x`"" | Should -BeExactly '"saved"'
        Get-PvmVirtualBoxVmState -Output 'name="x"' | Should -BeNullOrEmpty
    }

    It 'waits for VBoxSVC up to the timeout, once a second' {
        $script:clock = [datetime]'2026-01-01T00:00:00'
        Mock -ModuleName PortableVM Get-Date { $script:clock = $script:clock.AddSeconds(10); $script:clock }
        Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true }
        Mock -ModuleName PortableVM Invoke-PvmSleep {}
        Wait-PvmProcessExit -Name 'VBoxSVC' -TimeoutSeconds 30
        Should -Invoke -CommandName Invoke-PvmSleep -ModuleName PortableVM -Times 2 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }
}

Describe 'A start' {
    Context 'in VMware Workstation' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'vmware-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'finds the stick by its drive letter, points the descriptor at it with Data blanked, starts the VM and logs each step' {
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 0
            $result.Message | Should -BeNullOrEmpty
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $DriveLetter -ceq $script:stick.Letter }
            Should -Invoke -CommandName Invoke-PvmGetDisk -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Number -eq 3 }
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { ($Name -join ',') -ceq $script:vmwareNames }
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { ($Name -join ',') -ceq $script:virtualBoxVmNames }
            [IO.File]::ReadAllText($script:stick.VMwareDisk) | Should -BeLike '*RW 2500000 FLAT "\\.\PhysicalDrive3" 0*RW 1400000 ZERO*'
            [IO.File]::ReadAllText($script:stick.VMwareDisk) | Should -BeLike '*createType="fullDevice"*'
            [IO.File]::ReadAllText((Join-Path $script:stick.Backups 'VMware\stick.vmdk.orig')) |
                Should -BeExactly ((Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', '\\.\PortableVM-disarmed'))
            "$($script:stick.VMwareDisk).orig" | Should -Not -Exist
            @(Get-ChildItem -LiteralPath $script:stick.Launcher -Force) | Should -BeNullOrEmpty
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq (Join-Path $script:stick.VMwareDir 'vmware.exe') -and ($ArgumentList -join ' ') -ceq "-n -q -x `"$($script:stick.Vmx)`""
            }
            Get-TestLog -Path $script:stick.Log | Should -BeExactly @(
                '----- Start VM -----'
                'Launcher version unknown'
                "Stick found: disk 3 (\\.\PhysicalDrive3), drive $($script:stick.Letter):, ID 5CA1AB1E"
                'Using VMware'
                'stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0 | RW 1400000 ZERO'
                "Started with VMware Workstation ($($script:stick.VMwareDir))"
                '----- End: exit code 0 -----'
            )
        }

        It 'changes and starts nothing in a dry run, and logs what it would do' {
            $before = Get-TestTreeHash -Root $script:stick.Root
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 0
            $after = Get-TestTreeHash -Root $script:stick.Root
            @($after.Keys | Sort-Object) | Should -BeExactly @($before.Keys | Sort-Object)
            foreach ($path in $before.Keys) { $after[$path] | Should -BeExactly $before[$path] }
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
            Get-TestLog -Path $script:stick.Log | Should -BeExactly @(
                '----- Start VM (dry run) -----'
                'Launcher version unknown'
                "Stick found: disk 3 (\\.\PhysicalDrive3), drive $($script:stick.Letter):, ID 5CA1AB1E"
                'Using VMware'
                'stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0 | RW 1400000 ZERO'
                "DRY RUN - would start $($script:stick.Vmx) with VMware Workstation ($($script:stick.VMwareDir))"
                '----- End (dry run): exit code 0 -----'
            )
        }

        It 'creates no missing descriptor in a dry run' {
            Remove-Item -LiteralPath $script:stick.VMwareDisk
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $script:stick.VMwareDisk | Should -Not -Exist
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Creating stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0 | RW 1400000 ZERO'
        }

        It 'starts in full screen when VMwareView is FullScreen' {
            $script:stick = Initialize-TestStick -Name 'vmware-stick' -Change @{ VMwareView = 'FullScreen' }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -ccontains '-X') -and -not ($ArgumentList -ccontains '-x')
            }
        }

        It 'creates a missing descriptor' {
            Remove-Item -LiteralPath $script:stick.VMwareDisk
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            [IO.File]::ReadAllText($script:stick.VMwareDisk) | Should -BeLike '*ddb.adapterType = "ide"*'
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Creating stick.vmdk -> RW 2500000 FLAT "\\.\PhysicalDrive3" 0 | RW 1400000 ZERO'
        }

        It 'stops, rather than create a descriptor, when a rewrite of it was cut off, and starts nothing' {
            Rename-Item -LiteralPath $script:stick.VMwareDisk -NewName 'stick.vmdk.pvm-old'
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "A write of $($script:stick.VMwareDisk) did not finish. To set it right, rename stick.vmdk.pvm-old back to stick.vmdk. Nothing was started."
            $script:stick.VMwareDisk | Should -Not -Exist
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops without guessing, a dry run too, when <Case>' -Tag 'WindowsOnly' -ForEach @(
            @{ Case = 'the version before beside a copy cannot be read'; Held = 'old'
                Message = 'A write of <copy> did not finish, and Test VM.vbox.previous.launcher-backup.pvm-old beside it cannot be read. Close the program that holds it, then start again. Nothing was started.'
            }
            @{ Case = 'the file of a copy with its version before beside it cannot be read'; Held = 'file'
                Message = ('A write of <copy> did not finish, and the launcher cannot read <vbox> to tell which version of the copy to keep. Make <vbox> readable again, ' +
                    'for example by closing the program that holds it, then start again. Nothing was started.')
            }
        ) {
            $copy = Join-Path $script:stick.Backups 'VirtualBox\Test VM\Test VM.vbox.previous.launcher-backup'
            Write-TestFile -Path $copy -Text '<VirtualBox old="1"/>'
            [IO.File]::Copy($script:stick.Vbox, "$copy.pvm-old")
            $target = if ($Held -eq 'old') { "$copy.pvm-old" } else { $script:stick.Vbox }
            $handle = [IO.File]::Open($target, 'Open', 'Read', 'None')
            try {
                foreach ($dryRun in $false, $true) {
                    $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                    $result.ExitCode | Should -Be 1
                    $result.Message | Should -BeExactly $Message.Replace('<copy>', $copy).Replace('<vbox>', $script:stick.Vbox)
                }
            } finally {
                $handle.Dispose()
            }
        }

        It 'asks, a dry run too, for the file of a copy with its version before beside it to be put back when <Case>' -ForEach @(
            @{ Case = 'it is missing'; Folder = $false
                Message = ('A write of <copy> did not finish, and <file>, which it is a copy of, is missing, so the launcher cannot tell which version of the copy to keep. ' +
                    'Put <file> back, for example from its copies below LauncherData\backups, then start again. Nothing was started.')
            }
            @{ Case = 'a folder has its name'; Folder = $true
                Message = ('A write of <copy> did not finish, and a folder has the name of <file>, which it is a copy of, so the launcher cannot tell which version of the copy ' +
                    'to keep. Move that folder away and put <file> back, then start again. Nothing was started.')
            }
        ) {
            $copy = Join-Path $script:stick.Backups 'VMware\stick.vmdk.previous.orig'
            Write-TestFile -Path $copy -Text 'RW 1 FLAT "\\.\PortableVM-disarmed" 0'
            Write-TestFile -Path "$copy.pvm-old" -Text 'RW 2 FLAT "\\.\PortableVM-disarmed" 0'
            Remove-Item -LiteralPath $script:stick.VMwareDisk
            if ($Folder) { $null = New-Item -ItemType Directory -Path $script:stick.VMwareDisk }
            foreach ($dryRun in $false, $true) {
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly $Message.Replace('<copy>', $copy).Replace('<file>', $script:stick.VMwareDisk)
            }
        }

        It 'names, a dry run too, the step for a copy whose step needs no look at its missing file' {
            $copy = Join-Path $script:stick.Backups 'VMware\stick.vmdk.previous.orig'
            Write-TestFile -Path "$copy.pvm-old" -Text 'RW 2 FLAT "\\.\PortableVM-disarmed" 0'
            Remove-Item -LiteralPath $script:stick.VMwareDisk
            $expected = "A write of $copy did not finish. To set it right, rename stick.vmdk.previous.orig.pvm-old back to stick.vmdk.previous.orig. Nothing was started."
            foreach ($dryRun in $false, $true) {
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly $expected
            }
        }

        It 'keeps, a dry run too, the descriptor''s copy put back whose swap stopped between its renames, comparing the disarmed descriptor' {
            $copy = Join-Path $script:stick.Backups 'VMware\stick.vmdk.previous.orig'
            Write-TestFile -Path "$copy.pvm-old" -Text (Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', '\\.\PortableVM-disarmed')
            Write-TestFile -Path "$copy.pvm-tmp" -Text (Get-TestDescriptorText).Replace('\\.\PhysicalDrive1', '\\.\PortableVM-disarmed').Replace('3900000', '3800000')
            $expected = ("A write of $copy did not finish. To set it right, rename stick.vmdk.previous.orig.pvm-tmp to stick.vmdk.previous.orig and remove " +
                'stick.vmdk.previous.orig.pvm-old, which holds a copy of the file as it is now. Nothing was started.')
            foreach ($dryRun in $false, $true) {
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly $expected
            }
        }

        It 'names the step, in a start and a dry run, when a write of the .vbox did not finish and left it missing, and starts nothing' {
            Rename-Item -LiteralPath $script:stick.Vbox -NewName 'Test VM.vbox.pvm-old'
            [IO.File]::WriteAllText("$($script:stick.Vbox).pvm-tmp", '<VirtualBox/>')
            $message = "A write of $($script:stick.Vbox) did not finish. To set it right, rename Test VM.vbox.pvm-old back to Test VM.vbox and remove Test VM.vbox.pvm-tmp. Nothing was started."
            foreach ($dryRun in $false, $true) {
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly $message
            }
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops, a dry run too, at a write that did not finish of <Case>, although a VMware start does not change it' -ForEach @(
            @{ Case = 'the .vbox, which it left unreadable'; Setup = {
                    Copy-Item -LiteralPath $script:stick.Vbox -Destination "$($script:stick.Vbox).pvm-old"
                    [IO.File]::WriteAllBytes($script:stick.Vbox, (New-Object byte[] 64))
                }
                Step = '<vbox> did not finish. To set it right, remove Test VM.vbox, then rename Test VM.vbox.pvm-old back to Test VM.vbox, which holds the version before the write.'
            }
            @{ Case = 'VirtualBox.xml'; Setup = {
                    Rename-Item -LiteralPath $script:stick.VirtualBoxXml -NewName 'VirtualBox.xml.pvm-old'
                    [IO.File]::WriteAllText("$($script:stick.VirtualBoxXml).pvm-tmp", '<VirtualBox/>')
                }
                Step = '<xml> did not finish. To set it right, rename VirtualBox.xml.pvm-old back to VirtualBox.xml and remove VirtualBox.xml.pvm-tmp.'
            }
            @{ Case = 'a copy below LauncherData\backups'; Setup = {
                    Write-TestFile -Path (Join-Path $script:stick.Backups 'VirtualBox\Test VM\stick.vmdk.previous.orig.pvm-tmp') -Text 'x'
                }
                Step = '<copy> did not finish. To set it right, remove stick.vmdk.previous.orig.pvm-tmp, which may be incomplete.'
            }
            @{ Case = 'a first copy below LauncherData\backups'; Setup = {
                    Write-TestFile -Path (Join-Path $script:stick.Backups 'VirtualBox\VirtualBox.xml.launcher-backup') -Text '<VirtualBox/>'
                    Write-TestFile -Path (Join-Path $script:stick.Backups 'VirtualBox\VirtualBox.xml.launcher-backup.pvm-old') -Text '<VirtualBox old="1"/>'
                }
                Step = '<first> did not finish. To set it right, remove VirtualBox.xml.launcher-backup, then rename VirtualBox.xml.launcher-backup.pvm-old back to VirtualBox.xml.launcher-backup, which holds the version before the write.'
            }
        ) {
            & $Setup
            $copy = Join-Path $script:stick.Backups 'VirtualBox\Test VM\stick.vmdk.previous.orig'
            $first = Join-Path $script:stick.Backups 'VirtualBox\VirtualBox.xml.launcher-backup'
            $stop = 'A write of ' + $Step.Replace('<vbox>', $script:stick.Vbox).Replace('<xml>', $script:stick.VirtualBoxXml).Replace('<copy>', $copy).Replace('<first>', $first)
            $expected = $stop + ' Nothing was started.'
            foreach ($dryRun in $false, $true) {
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly $expected
            }
            Get-TestLog -Path $script:stick.Log | Should -Contain "DRY RUN - a real start would stop here: $expected"
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'keeps the first version of the descriptor and the version before the latest rewrite below LauncherData\backups' {
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $folder = Join-Path $script:stick.Backups 'VMware'
            @(Get-ChildItem -LiteralPath $folder -Name | Sort-Object) | Should -BeExactly @('stick.vmdk.orig', 'stick.vmdk.previous.orig')
            [IO.File]::ReadAllText((Join-Path $folder 'stick.vmdk.previous.orig')) | Should -BeLike '*"\\.\PortableVM-disarmed"*'
            @(Get-ChildItem -LiteralPath (Split-Path $script:stick.VMwareDisk) -Name -Filter '*.pvm-*') | Should -BeNullOrEmpty
        }

        It 'reports a VM that already runs in VMware' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = "vmware-vmx.exe `"$($script:stick.Vmx)`"" })
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 0
            $result.Message | Should -BeExactly 'The VM is already running.'
            $result.Icon | Should -BeExactly 'Information'
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeExactly 'Already running in VMware.'
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops while a VirtualBox VM runs that may be this one: <Case>' -ForEach @(
            @{ Case = 'VirtualBoxVM.exe without a readable command line'; Process = @{ Name = 'VirtualBoxVM.exe'; CommandLine = $null } }
            @{ Case = 'VBoxHeadless.exe naming the UUID'; Process = @{ Name = 'VBoxHeadless.exe'; CommandLine = 'VBoxHeadless.exe --startvm 5ca1ab1e-0000-4000-8000-000000000001' } }
        ) {
            $script:testProcesses = @([pscustomobject]$Process)
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly 'A VirtualBox VM is running, possibly this one. Close it before starting the VM in VMware - the stick must never be used by two VMs at once.'
            $result.Icon | Should -BeExactly 'Error'
        }

        It 'starts while a VirtualBox VM runs another VM' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'VBoxHeadless.exe'; CommandLine = 'VBoxHeadless.exe --startvm 5ca1ab1e-0000-4000-8000-000000000009' })
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).ExitCode | Should -Be 0
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        }

        It 'stops while VirtualBox holds a saved state, but a dry run carries on' {
            [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            $message = 'The VM has a saved state in VirtualBox. Resume it in VirtualBox (on a PC with VirtualBox) and shut the guest down normally before starting it in VMware - otherwise the guest''s disk can get corrupted.'
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly $message
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Saved state found: saved in VirtualBox'
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeExactly "STOPPED: $message"

            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly $message
            Get-TestLog -Path $script:stick.Log | Should -Contain "DRY RUN - a real start would stop here: $message"
        }
    }

    Context 'in VirtualBox' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'virtualbox-stick'
            Set-TestPc -Stick $script:stick -Installed 'VirtualBox'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'names the step, in a start and a dry run, when a write of the .vbox did not finish and left it missing, and starts nothing' {
            Rename-Item -LiteralPath $script:stick.Vbox -NewName 'Test VM.vbox.pvm-old'
            [IO.File]::WriteAllText("$($script:stick.Vbox).pvm-tmp", '<VirtualBox/>')
            $message = "A write of $($script:stick.Vbox) did not finish. To set it right, rename Test VM.vbox.pvm-old back to Test VM.vbox and remove Test VM.vbox.pvm-tmp. Nothing was started."
            foreach ($dryRun in $false, $true) {
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dryRun
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly $message
            }
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
        }

        It 'stops at a write of the VMware descriptor that did not finish, although a VirtualBox start does not change it' {
            [IO.File]::WriteAllText("$($script:stick.VMwareDisk).pvm-tmp", 'x')
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "A write of $($script:stick.VMwareDisk) did not finish. To set it right, remove stick.vmdk.pvm-tmp; stick.vmdk itself is whole. Nothing was started."
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
        }

        It 'starts nothing when the old version of a rewritten file cannot be removed, and names the step that puts it back' {
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { [IO.File]::Delete($Path) }
            Mock -ModuleName PortableVM Remove-PvmWriteCopy { throw [IO.IOException]::new('The process cannot access the file.', [int]0x80070020) } -ParameterFilter { (Split-Path $Path -Leaf) -eq 'Test VM.vbox.pvm-old' }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly ("A write of $($script:stick.Vbox) did not finish. To set it right, remove Test VM.vbox, then rename Test VM.vbox.pvm-old back to Test VM.vbox, " +
                'which holds the version before the write. Nothing was started.')
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
        }

        It 'gives the drive-letter rule the paths to the VM''s own files, which a stick folder at a drive root needs' {
            Mock -ModuleName PortableVM Get-PvmDriveLetterChange { $null }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            Should -Invoke -CommandName Get-PvmDriveLetterChange -ModuleName PortableVM -Times 2 -Exactly -ParameterFilter {
                ($Known -join '|') -ceq "$($script:stick.Vbox)|$($script:stick.VirtualBoxDisk)"
            }
        }

        It 'leaves the .vbox as it was when VirtualBox.xml is read-only' -Tag 'WindowsOnly' {
            $vbox = [IO.File]::ReadAllText($script:stick.Vbox)
            [IO.File]::SetAttributes($script:stick.VirtualBoxXml, 'ReadOnly')
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "$($script:stick.VirtualBoxXml) is read-only, so the launcher does not rewrite it. Clear that attribute, then start again. Nothing was started."
            [IO.File]::ReadAllText($script:stick.Vbox) | Should -BeExactly $vbox
        }

        It 'checks every file before it changes the first one, so a refused descriptor leaves the others as they were' {
            Write-TestFile -Path $script:stick.VirtualBoxDisk -Text "createType=`"monolithicSparse`"`r`nRW 17 SPARSE `"disk.vmdk`"`r`n"
            $before = Get-TestTreeHash -Root $script:stick.Root
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike "Unexpected content in $($script:stick.VirtualBoxDisk) - line 2 has a SPARSE extent*"
            $after = Get-TestTreeHash -Root $script:stick.Root
            @($before.Keys | Where-Object { $after[$_] -ne $before[$_] }) | Should -BeNullOrEmpty
            @($after.Keys).Count | Should -Be @($before.Keys).Count
            $log = Get-TestLog -Path $script:stick.Log
            $log | Should -Contain ('Test VM.vbox: paths moved to drive ' + $script:stick.Letter + ':')
        }

        It 'fixes the drive letter, points the descriptor at the stick, starts the VM and logs each step' {
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 0
            # The .vbox names the stick by its Windows path, which off Windows is made up.
            $below = $script:stick.WindowsPath.Substring(2)
            [IO.File]::ReadAllText($script:stick.Vbox) | Should -BeLike "*location=`"$($script:stick.Letter):$below\VirtualBox\Test VM\stick.vmdk`"*"
            [IO.File]::ReadAllText($script:stick.VirtualBoxXml) | Should -BeLike "*src=`"$($script:stick.Letter):$($below.Replace('\', '/'))/VirtualBox/Test VM/Test VM.vbox`"*"
            Join-Path $script:stick.Backups 'VirtualBox\Test VM\Test VM.vbox.launcher-backup' | Should -Exist
            Join-Path $script:stick.Backups 'VirtualBox\VirtualBox.xml.launcher-backup' | Should -Exist
            Join-Path $script:stick.Backups 'VirtualBox\Test VM\stick.vmdk.orig' | Should -Exist
            "$($script:stick.Vbox).launcher-backup" | Should -Not -Exist
            "$($script:stick.VirtualBoxXml).launcher-backup" | Should -Not -Exist
            [IO.File]::ReadAllText($script:stick.VirtualBoxDisk) | Should -BeExactly ((Get-TestDescriptorText -Newline "`n").Replace('PhysicalDrive1', 'PhysicalDrive3'))
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { ($Name -join ',') -ceq $script:vmwareNames }
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { ($Name -join ',') -ceq $script:virtualBoxOpenNames }
            Should -Invoke -CommandName Invoke-PvmSetEnvironment -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'VBOX_USER_HOME' -and $Value -eq (Join-Path $script:stick.Root 'VirtualBox')
            }
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq "startvm $script:uuid --type gui" }
            Get-TestLog -Path $script:stick.Log | Should -BeExactly @(
                '----- Start VM -----'
                'Launcher version unknown'
                "Stick found: disk 3 (\\.\PhysicalDrive3), drive $($script:stick.Letter):, ID 5CA1AB1E"
                'Using VirtualBox'
                "Test VM.vbox: paths moved to drive $($script:stick.Letter):"
                "VirtualBox.xml: paths moved to drive $($script:stick.Letter):"
                'stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0'
                'VirtualBox VM state: "poweroff"'
                'Started with VirtualBox 7.1.4r165100'
                '----- End: exit code 0 -----'
            )
        }

        It 'blanks the Data partition when HideDataPartition is set' {
            $script:stick = Initialize-TestStick -Name 'virtualbox-stick' -Change @{ HideDataPartition = $true }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            [IO.File]::ReadAllText($script:stick.VirtualBoxDisk) | Should -BeLike "*createType=`"partitionedDevice`"*RW 2500000 FLAT `"\\.\PhysicalDrive3`" 0`nRW 1400000 ZERO*"
        }

        It 'changes and starts nothing in a dry run, and asks VBoxManage nothing' {
            $before = Get-TestTreeHash -Root $script:stick.Root
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 0
            $after = Get-TestTreeHash -Root $script:stick.Root
            @($after.Keys | Sort-Object) | Should -BeExactly @($before.Keys | Sort-Object)
            foreach ($path in $before.Keys) { $after[$path] | Should -BeExactly $before[$path] }
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly
            Get-TestLog -Path $script:stick.Log | Should -BeExactly @(
                '----- Start VM (dry run) -----'
                'Launcher version unknown'
                "Stick found: disk 3 (\\.\PhysicalDrive3), drive $($script:stick.Letter):, ID 5CA1AB1E"
                'Using VirtualBox'
                "Test VM.vbox: paths moved to drive $($script:stick.Letter):"
                "VirtualBox.xml: paths moved to drive $($script:stick.Letter):"
                'stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0'
                "DRY RUN - would start VM {$script:uuid} with VirtualBox ($($script:stick.VirtualBoxDir))"
                '----- End (dry run): exit code 0 -----'
            )
        }

        It 'reports a VM that already runs while VirtualBox is open' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = 'VMState="running"' } } -ParameterFilter { $ArgumentList[0] -eq 'showvminfo' }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly 'The VM is already running.'
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeExactly 'Already running in VirtualBox.'
        }

        It 'stops while VirtualBox is open with another VM, but a dry run carries on' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
            $message = 'VirtualBox is already open on this PC. Close all VirtualBox windows, then start the VM again.'
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeExactly $message
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            Get-TestLog -Path $script:stick.Log | Should -Contain "DRY RUN - a real start would stop here: $message"
        }

        It 'stops while VBoxSVC still runs after the wait' {
            Mock -ModuleName PortableVM Wait-PvmProcessExit {}
            Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true } -ParameterFilter { $Name -eq 'VBoxSVC' }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly 'VirtualBox is still running in the background. Wait half a minute, then start the VM again.'
            Should -Invoke -CommandName Wait-PvmProcessExit -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Name -eq 'VBoxSVC' -and $TimeoutSeconds -eq 30 }
        }

        It 'waits for VBoxSVC in a dry run as in a real start, and logs the wait' {
            Mock -ModuleName PortableVM Wait-PvmProcessExit { $script:waits++ }
            Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true } -ParameterFilter { $Name -eq 'VBoxSVC' }
            foreach ($dry in $false, $true) {
                $script:waits = 0
                $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dry
                $result.ExitCode | Should -Be 1
                $result.Message | Should -BeExactly 'VirtualBox is still running in the background. Wait half a minute, then start the VM again.'
                $script:waits | Should -Be 1
            }
            @(Get-TestLog -Path $script:stick.Log | Where-Object { $_ -ceq "Waiting up to 30 s for VirtualBox's background service (VBoxSVC) to end" }).Count | Should -Be 2
        }

        It 'does not wait for VBoxSVC in a dry run that found a stop before the wait' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
            Mock -ModuleName PortableVM Wait-PvmProcessExit { $script:waits++ }
            Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true } -ParameterFilter { $Name -eq 'VBoxSVC' }
            $script:waits = 0
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly 'VirtualBox is already open on this PC. Close all VirtualBox windows, then start the VM again.'
            $script:waits | Should -Be 0
        }

        It 'stops when the VM list lacks the VM' {
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = '"Other" {5ca1ab1e-0000-4000-8000-000000000009}' } } -ParameterFilter { $ArgumentList[0] -eq 'list' }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message |
                Should -BeExactly "VirtualBox did not find the VM in the stick's VM list:`n`n`"Other`" {5ca1ab1e-0000-4000-8000-000000000009}"
        }

        It 'reports a VM that runs by the time VBoxManage asks, without the window note' {
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = 'VMState="paused"' } } -ParameterFilter { $ArgumentList[0] -eq 'showvminfo' }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeExactly 'The VM is already running.'
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeExactly 'VirtualBox VM state: "paused"'
        }

        It 'stops with VBoxManage''s output when the start fails' {
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 1; Output = 'error: the raw disk is locked' } } -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "VirtualBox could not start the VM:`n`nerror: the raw disk is locked"
        }

        It 'stops while the VM runs in VMware' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = $null })
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeExactly 'The VM is running in VMware. Close it before starting it in VirtualBox.'
        }

        It 'stops while the VM is suspended in VMware, but a dry run carries on' {
            Add-Content -LiteralPath $script:stick.Vmx -Value 'checkpoint.vmState = "Test VM.vmss"'
            $message = 'The VM is suspended in VMware. Resume it in VMware (on a PC with VMware Workstation) and shut the guest down normally before starting it in VirtualBox - otherwise the guest''s disk can get corrupted.'
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly $message
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeExactly "STOPPED: $message"
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly

            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly $message
            Get-TestLog -Path $script:stick.Log | Should -Contain "DRY RUN - a real start would stop here: $message"
        }
    }

    Context 'that chooses between the two' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'both-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware', 'VirtualBox'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'resumes a VMware suspend in VMware, after a Yes' {
            Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"')
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Saved state found: suspended in VMware'
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Using VMware'
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        }

        It 'resumes a VirtualBox save in VirtualBox, after a Yes' {
            [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Using VirtualBox'
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Resume of the saved state in VirtualBox confirmed.'
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
        }

        It 'stops, rather than use VirtualBox, when the .vmx is missing' {
            Remove-Item -LiteralPath $script:stick.Vmx
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).ExitCode | Should -Be 1
            Get-TestLog -Path $script:stick.Log | Should -Not -Contain 'Using VirtualBox'
        }

        It 'uses VirtualBox when the setting says so' {
            $script:stick = Initialize-TestStick -Name 'both-stick' -Change @{ Hypervisor = 'VirtualBox' }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Using VirtualBox'
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }
    }

    Context 'that cannot begin' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'other-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware', 'VirtualBox'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'stops on another disk and logs why' {
            Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk -Change @{ Signature = [uint32]0x5CA1AB1F } } -ParameterFilter { $Number -eq 3 }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly 'This is not the expected USB stick (disk ID 5CA1AB1F, expected 5CA1AB1E). Nothing was started.'
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeExactly "STOPPED: $($result.Message)"
        }

        It 'stops at once on a missing settings file, naming it' {
            Remove-Item -LiteralPath $script:stick.Settings
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "LauncherData\settings.psd1 is missing. Copy examples\settings.example.psd1 there and fill it in.`n`nNothing was started."
            # The message spans lines, each with its prefix, so the log is compared as text.
            ((Get-TestLog -Path $script:stick.Log) -join "`n").EndsWith("STOPPED: $($result.Message)`n----- End: exit code 1 -----") | Should -BeTrue
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops before it reads the PC on settings with problems, naming each bad key and no value' {
            $script:stick = Initialize-TestStick -Name 'other-stick' -Change @{ Hypervisor = 'VBox'; StickSectors = '4000000'; VMwareVmx = '..\Test VM.vmx' }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly ("LauncherData\settings.psd1 has 3 problems:`n" +
                "- Hypervisor: must be 'Auto', 'VMware' or 'VirtualBox'`n" +
                "- StickSectors: must be a whole number above 0`n" +
                "- VMwareVmx: must name a .vmx file below the folder that holds Launcher and LauncherData, without a drive, '.' or '..'`n`nNothing was started.")
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops on schema 1 settings, saying how to fix them' {
            Write-TestFile -Path $script:stick.Settings -Text (ConvertTo-TestSettingsText -Settings (Get-TestSettingTable -Change @{ SchemaVersion = $null }))
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message |
                Should -BeExactly "LauncherData\settings.psd1 has 1 problem:`n- SchemaVersion: missing; add SchemaVersion = 2 (see examples\settings.example.psd1)`n`nNothing was started."
        }

        It 'stops while Launcher holds a settings file, which it no longer reads' {
            Write-TestFile -Path (Join-Path $script:stick.Launcher 'settings.psd1') -Text (ConvertTo-TestSettingsText -Settings (Get-TestSettingTable))
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike 'Launcher\settings.psd1 is there, but the launcher reads its settings from LauncherData\settings.psd1.*'
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops without LauncherData, creating and logging nothing, and names the migration when the old settings are there' {
            Remove-Item -LiteralPath $script:stick.Data -Recurse
            $before = @(Get-ChildItem -LiteralPath $script:stick.Root -Recurse -Force | ForEach-Object { $_.FullName })
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Caption | Should -BeExactly 'Portable VM'
            $result.Message | Should -BeLike 'LauncherData, the folder beside Launcher that holds the settings and the log, is missing.*'
            @(Get-ChildItem -LiteralPath $script:stick.Root -Recurse -Force | ForEach-Object { $_.FullName }) | Should -BeExactly $before
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-PvmTestAdministrator -ModuleName PortableVM -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-PvmEnterLock -ModuleName PortableVM -Times 0 -Exactly

            Write-TestFile -Path (Join-Path $script:stick.Launcher 'settings.psd1') -Text (ConvertTo-TestSettingsText -Settings (Get-TestSettingTable -Change @{ SchemaVersion = $null }))
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun).Message | Should -BeLike '*tools\Deploy-PortableVM.ps1 -MigrateSettings*'
            $script:stick.Data | Should -Not -Exist
        }

        It 'says so when the launcher''s own folder is gone, as when the stick was pulled' {
            $result = Invoke-PortableVM -LauncherPath (Join-Path $script:stick.Root 'gone\Launcher')
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly 'The launcher''s own folder cannot be found any more, as when the USB stick was removed. Plug the stick in, then start the VM again. Nothing was started.'
            Should -Invoke -CommandName Invoke-PvmTestAdministrator -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'creates the logs folder when it is missing, also in a dry run' {
            $script:stick.Log | Should -Not -Exist
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun).ExitCode | Should -Be 0
            (Get-TestLog -Path $script:stick.Log)[0] | Should -BeExactly '----- Start VM (dry run) -----'
        }

        It 'stops when neither hypervisor is installed' {
            $script:testInstalled = @()
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeExactly 'Neither VMware Workstation nor VirtualBox is installed on this PC.'
        }

        It 'stops when the chosen VMware Workstation is not installed' {
            $script:stick = Initialize-TestStick -Name 'other-stick' -Change @{ Hypervisor = 'VMware' }
            $script:testInstalled = @('VirtualBox')
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeExactly 'VMware Workstation is not installed on this PC.'
        }

        It 'logs a VMware suspend before the .vbox can fail' {
            # The .vbox is a folder, which cannot be read as a file.
            Remove-Item -LiteralPath $script:stick.Vbox
            $null = New-Item -ItemType Directory -Path $script:stick.Vbox
            Add-Content -LiteralPath $script:stick.Vmx -Value 'checkpoint.vmState = "Test VM.vmss"'
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $log = Get-TestLog -Path $script:stick.Log
            $log[-3] | Should -BeExactly 'Saved state found: suspended in VMware'
            $log[-2] | Should -BeLike 'STOPPED: The launcher cannot tell whether the VM has a saved state in VirtualBox, because the path is a folder, not a file: VirtualBoxVbox in settings.psd1 names *'
        }

        It 'logs the version from VERSION and the note on Memory Integrity' {
            Write-TestFile -Path (Join-Path $script:stick.Launcher 'VERSION') -Text "v0.2.0`n"
            Mock -ModuleName PortableVM Invoke-PvmGetDeviceGuard { [pscustomobject]@{ SecurityServicesRunning = @(1, 2) } }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Launcher version v0.2.0'
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'
        }

        It 'starts although VERSION cannot be read' -Tag 'WindowsOnly' {
            $version = Join-Path $script:stick.Launcher 'VERSION'
            Write-TestFile -Path $version -Text "v0.2.0`n"
            $lock = [IO.File]::Open($version, 'Open', 'Read', 'None')
            try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher }
            finally { $lock.Dispose() }
            $result.ExitCode | Should -Be 0
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Launcher version unreadable'
        }
    }

    Context 'that guards against a suspend' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'guard-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware', 'VirtualBox'
            $script:suspended = Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'stops a VMware start without <Key>, naming the line to add, but a dry run carries on' -ForEach @(
            @{ Key = 'suspend.disabled'; Message = 'The VM''s .vmx lacks suspend.disabled = "TRUE", *' }
            @{ Key = 'uuid.action'; Message = 'The VM''s .vmx lacks uuid.action = "keep", *' }
        ) {
            Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Without $Key)
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike $Message
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike $Message
            @(Get-TestLog -Path $script:stick.Log | Where-Object { $_ -like "DRY RUN - a real start would stop here: $Message" }).Count | Should -Be 1
        }

        It 'asks before it resumes a VMware suspend, and logs the Yes' {
            Write-TestFile -Path $script:stick.Vmx -Text $script:suspended
            $script:question = $null
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { param($Question) $script:question = $Question; $true }
            $result.ExitCode | Should -Be 0
            $script:question | Should -BeExactly "The VM is suspended in VMware. Resume it only if the stick has not been booted any other way since the suspend; otherwise the resume can corrupt the guest's disk.`n`nResume the VM now?"
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Resume of the saved state in VMware confirmed.'
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        }

        It 'resumes nothing after a No, without a way to ask, or with SavedStatePolicy Refuse' {
            Write-TestFile -Path $script:stick.Vmx -Text $script:suspended
            $notResumed = 'The saved state in VMware was not resumed. Nothing was started. Start the VM again to be asked again*'
            foreach ($answer in { $false }, { 'No' }, { $false; $false }, { $true; $true }) {
                (Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume $answer).Message | Should -BeLike $notResumed
            }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeLike $notResumed
            (Get-TestLog -Path $script:stick.Log)[-2] | Should -BeLike "STOPPED: $notResumed"
            $script:stick = Initialize-TestStick -Name 'guard-stick' -Change @{ SavedStatePolicy = 'Refuse' }
            Write-TestFile -Path $script:stick.Vmx -Text $script:suspended
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }).Message |
                Should -BeLike "The VM has a saved state in VMware, and SavedStatePolicy in settings.psd1 is 'Refuse', so the launcher does not resume it.*"
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops a suspended VM whose .vmx lacks suspend.disabled, saying it still resumes with the line' {
            Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Without 'suspend.disabled' -Add 'checkpoint.vmState = "Test VM.vmss"')
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike '*a VM that is suspended now still resumes with the line*'
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'names a wrong value of suspend.disabled' {
            Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Without 'suspend.disabled' -Add 'suspend.disabled = "FALSE"')
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeLike 'The VM''s .vmx has suspend.disabled = "FALSE" instead of "TRUE", *'
        }

        It 'asks before it resumes a VirtualBox save, and resumes nothing after a No' {
            [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $false }).Message | Should -BeLike 'The saved state in VirtualBox was not resumed. Nothing was started.*'
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }).ExitCode | Should -Be 0
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
        }

        It 'only logs the question in a dry run' {
            [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun -AskResume { throw 'A dry run must not ask.' }
            $result.ExitCode | Should -Be 0
            Get-TestLog -Path $script:stick.Log | Should -Contain 'DRY RUN - a real start would ask whether to resume the saved state in VirtualBox.'
        }

        It 'stops when it cannot tell a saved state: <Case>' -ForEach @(
            @{ Case = 'a missing .vmx'; Setup = { Remove-Item -LiteralPath $script:stick.Vmx }; Message = 'The launcher cannot tell whether the VM is suspended in VMware, because the file does not exist: VMwareVmx in settings.psd1 names *' }
            @{ Case = 'a .vmx without config.version'; Setup = { Write-TestFile -Path $script:stick.Vmx -Text 'displayName = "Test VM"' }; Message = 'The launcher cannot tell whether the VM is suspended in VMware, because the file is no complete .vmx*' }
            @{ Case = 'a .vmx that sets suspend.disabled twice'; Setup = { Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'suspend.disabled = "TRUE"') }; Message = 'The launcher cannot tell whether the VM is suspended in VMware, because the file sets suspend.disabled more than once*' }
            @{ Case = 'a .vbox that is no XML'; Setup = { Write-TestFile -Path $script:stick.Vbox -Text '<VirtualBox' }; Message = 'The launcher cannot tell whether the VM has a saved state in VirtualBox, because the file is no valid XML*' }
        ) {
            & $Setup
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike $Message
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        }
    }

    Context 'with display names' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'names-stick' -Change @{ VmDisplayName = 'Test VM'; GuestName = 'Test OS' }
            Set-TestPc -Stick $script:stick -Installed 'VMware', 'VirtualBox'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'names the VM and the guest in a stop and uses the VM''s name as the title' {
            $script:stick = Initialize-TestStick -Name 'names-stick' -Change @{ VmDisplayName = 'Test VM'; GuestName = 'Test OS'; Hypervisor = 'VMware' }
            [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly 'Test VM has a saved state in VirtualBox. Resume it in VirtualBox (on a PC with VirtualBox) and shut Test OS down normally before starting it in VMware - otherwise Test OS''s disk can get corrupted.'
            $result.Caption | Should -BeExactly 'Test VM'
        }

        It 'names the VM in the already-running message' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = "vmware-vmx.exe `"$($script:stick.Vmx)`"" })
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly 'Test VM is already running.'
            $result.Caption | Should -BeExactly 'Test VM'
        }

        It 'asks with the names in the question and the VM''s name as the title' {
            Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"')
            $script:asked = $null
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { param($Question, $Caption) $script:asked = @($Question, $Caption); $true }
            $script:asked[0] | Should -BeExactly "Test VM is suspended in VMware. Resume it only if the stick has not been booted any other way since the suspend; otherwise the resume can corrupt Test OS's disk.`n`nResume Test VM now?"
            $script:asked[1] | Should -BeExactly 'Test VM'
        }

        It 'keeps the neutral words and the title Portable VM with the default names' {
            $script:stick = Initialize-TestStick -Name 'names-stick' -Change @{ VmDisplayName = 'The VM' }
            $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = "vmware-vmx.exe `"$($script:stick.Vmx)`"" })
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly 'The VM is already running.'
            $result.Caption | Should -BeExactly 'Portable VM'
        }
    }
}

Describe 'The log' -Tag 'WindowsOnly' {
    BeforeEach {
        Mock -ModuleName PortableVM Write-Host {}
        & (Get-Module PortableVM) { $script:PvmLogProblem = '' }
        $script:logFolder = Join-Path $TestDrive 'log'
        Remove-Item -LiteralPath $script:logFolder -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path $script:logFolder
        $script:log = Join-Path $script:logFolder 'launcher.log'
        $script:time = [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(1))
    }

    It 'prefixes every line of a message with the time, its UTC offset and the process ID' {
        Format-PvmLogText -Time $script:time -ProcessId 4242 -Message "a`r`nb`nc`rd" | Should -BeExactly (@(
                '2026-11-12T10:15:30.123+01:00 [4242]  a', '2026-11-12T10:15:30.123+01:00 [4242]  b',
                '2026-11-12T10:15:30.123+01:00 [4242]  c', '2026-11-12T10:15:30.123+01:00 [4242]  d') -join "`r`n")
        Format-PvmLogText -Time $script:time -ProcessId 4242 -Message '' | Should -BeExactly '2026-11-12T10:15:30.123+01:00 [4242]  '
        Format-PvmLogText -Time ([DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(-5))) -ProcessId 4242 -Message 'x' |
            Should -BeExactly '2026-11-12T10:15:30.123-05:00 [4242]  x'
    }

    It 'writes the same prefix under a culture with <Case>' -ForEach @(
        @{ Case = 'another time separator'; CultureName = 'fi-FI'; LocalText = '2026 10.15.30' }
        @{ Case = 'another calendar'; CultureName = 'th-TH'; LocalText = '2569 10:15:30' }
    ) {
        $previous = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new($CultureName)
            $script:time.ToString('yyyy HH:mm:ss') | Should -BeExactly $LocalText
            Format-PvmLogText -Time $script:time -ProcessId 4242 -Message 'x' | Should -BeExactly '2026-11-12T10:15:30.123+01:00 [4242]  x'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $previous
        }
    }

    It 'keeps the message after the first two consecutive spaces, in the format before phase 4 too' {
        '2026-11-12T10:15:30.123+01:00 [4242]  a  b' -replace '^.*?  ', '' | Should -BeExactly 'a  b'
        '2026-11-12 10:15:30  a  b' -replace '^.*?  ', '' | Should -BeExactly 'a  b'
    }

    # tests\Repo.Tests.ps1 pins the one write; this test shows the lines staying together while
    # another writer holds the log open for appending.
    It 'appends a message with its lines together while another writer holds the log open' {
        $other = Open-PvmAppendStream -Path $script:log
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes("other 1`r`n")
            $other.Write($bytes, 0, $bytes.Length)
            $other.Flush()
            Write-PvmLog -Path $script:log -Message "x`ny"
            $bytes = [Text.Encoding]::ASCII.GetBytes("other 2`r`n")
            $other.Write($bytes, 0, $bytes.Length)
            $other.Flush()
        } finally {
            $other.Dispose()
        }
        $lines = [IO.File]::ReadAllLines($script:log)
        $lines.Count | Should -Be 4
        $lines[0] | Should -BeExactly 'other 1'
        $lines[1] | Should -Match ('\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[' + $PID + '\]  x\z')
        $lines[2] | Should -Match ('\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[' + $PID + '\]  y\z')
        $lines[3] | Should -BeExactly 'other 2'
    }

    It 'writes in the system''s ANSI code page, as Windows PowerShell 5.1 always has, also under PowerShell 7' {
        (Get-PvmAnsiEncoding).CodePage | Should -Be (Get-TestAnsiEncoding).CodePage
        Write-PvmLog -Path $script:log -Message "caf$([char]0xE9)"
        $bytes = [IO.File]::ReadAllBytes($script:log)
        $expected = (Get-TestAnsiEncoding).GetBytes("caf$([char]0xE9)`r`n")
        [Convert]::ToBase64String($bytes, $bytes.Length - $expected.Length, $expected.Length) | Should -BeExactly ([Convert]::ToBase64String($expected))
    }

    It 'shows each message on the console, in the log''s format, as it writes it' {
        Mock -ModuleName PortableVM Get-PvmNow { [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(1)) }
        $script:shown = Format-PvmLogText -Time $script:time -ProcessId $PID -Message "x`ny"
        Write-PvmLog -Path $script:log -Message "x`ny"
        Should -Invoke -CommandName Write-Host -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { "$Object" -ceq $script:shown }
        [IO.File]::ReadAllText($script:log) | Should -BeExactly "$script:shown`r`n"
    }

    It 'names a missing part of a long file path as a path that is too long: <Case>' -ForEach @(
        @{ Case = 'a path of 260 characters'; Length = 260; HResult = 0x80070003; Cause = 'a path is too long' }
        @{ Case = 'a path of 259 characters'; Length = 259; HResult = 0x80070003; Cause = 'it is missing' }
        @{ Case = 'a long path held by another program'; Length = 300; HResult = 0x80070020; Cause = 'it is open in another program' }
    ) {
        $record = [System.Management.Automation.ErrorRecord]::new([IO.IOException]::new('x', [int]$HResult), 'Test', 'NotSpecified', $null)
        Get-PvmPathCause -Path ('X:\' + 'a' * ($Length - 3)) -ErrorRecord $record | Should -BeExactly $Cause
    }

    It 'words a cause for the place after "because": <Cause>' -ForEach @(
        @{ Cause = 'it is open in another program'; Text = 'it is open in another program' }
        @{ Cause = 'an error of type IOException'; Text = 'of an error of type IOException' }
    ) {
        Format-PvmBecause -Cause $Cause | Should -BeExactly $Text
    }

    It 'never throws, and says once on the console why the log cannot be written' {
        $null = New-Item -ItemType Directory -Path $script:log
        { foreach ($n in 1..3) { Write-PvmLog -Path $script:log -Message "line $n" } } | Should -Not -Throw
        Get-PvmLogProblem | Should -BeExactly 'it is a folder, not a file'
        Should -Invoke -CommandName Write-Host -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { "$Object" -ceq 'launcher.log could not be written: it is a folder, not a file' }
    }
}

Describe 'Log rotation' {
    BeforeEach {
        Mock -ModuleName PortableVM Write-Host {}
        & (Get-Module PortableVM) { $script:PvmLogProblem = '' }
        $script:logFolder = Join-Path $TestDrive 'rotation'
        Remove-Item -LiteralPath $script:logFolder -Recurse -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path $script:logFolder
        $script:log = Join-Path $script:logFolder 'launcher.log'
        $script:time = [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(1))
        $script:moved = Join-Path $script:logFolder 'launcher-20261112-101530.log'
    }

    It 'leaves a missing, an empty and a small log in the format alone' {
        Move-PvmOldLog -Path $script:log -Time $script:time | Should -BeNullOrEmpty
        [IO.File]::WriteAllText($script:log, '')
        Move-PvmOldLog -Path $script:log -Time $script:time | Should -BeNullOrEmpty
        [IO.File]::WriteAllText($script:log, (Format-PvmLogText -Time $script:time -ProcessId 1 -Message 'line') + "`r`n")
        Move-PvmOldLog -Path $script:log -Time $script:time | Should -BeNullOrEmpty
        # A time west of UTC and the longest process ID give the longest prefix, 44 characters.
        $west = [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(-5))
        [IO.File]::WriteAllText($script:log, (Format-PvmLogText -Time $west -ProcessId ([int]::MaxValue) -Message 'line') + "`r`n")
        Move-PvmOldLog -Path $script:log -Time $script:time | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:logFolder -Name) | Should -BeExactly @('launcher.log')
    }

    It 'moves a log of 1 MiB aside under the time, unchanged' {
        [IO.File]::WriteAllBytes($script:log, (New-Object byte[] 1MB))
        $hash = (Get-FileHash -LiteralPath $script:log -Algorithm SHA256).Hash
        $result = Move-PvmOldLog -Path $script:log -Time $script:time
        $result.Name | Should -BeExactly 'launcher-20261112-101530.log'
        $result.Problem | Should -BeExactly ''
        (Get-FileHash -LiteralPath $script:moved -Algorithm SHA256).Hash | Should -BeExactly $hash
        $script:log | Should -Not -Exist
    }

    It 'moves a log in the format aside once it holds 1 MiB, and not a byte before' {
        $head = [Text.Encoding]::ASCII.GetBytes((Format-PvmLogText -Time $script:time -ProcessId 1 -Message 'line') + "`r`n")
        foreach ($case in @(@{ Size = 1MB - 1; Name = $null }, @{ Size = 1MB; Name = 'launcher-20261112-101530.log' })) {
            $bytes = New-Object byte[] $case.Size
            [Array]::Copy($head, $bytes, $head.Length)
            [IO.File]::WriteAllBytes($script:log, $bytes)
            $result = Move-PvmOldLog -Path $script:log -Time $script:time
            if ($null -eq $case.Name) { $result | Should -BeNullOrEmpty } else { $result.Name | Should -BeExactly $case.Name }
        }
        @(Get-ChildItem -LiteralPath $script:logFolder -Name) | Should -BeExactly @('launcher-20261112-101530.log')
    }

    It 'names the moved log by the time in the Gregorian calendar under a culture with another one' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('th-TH')
            $script:time.ToString('yyyy') | Should -BeExactly '2569'
            [IO.File]::WriteAllBytes($script:log, (New-Object byte[] 1MB))
            (Move-PvmOldLog -Path $script:log -Time $script:time).Name | Should -BeExactly 'launcher-20261112-101530.log'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }
    }

    It 'moves a small log in the format before phase 4 aside' {
        [IO.File]::WriteAllText($script:log, "2026-11-12 10:15:30  old line`r`n")
        (Move-PvmOldLog -Path $script:log -Time $script:time).Name | Should -BeExactly 'launcher-20261112-101530.log'
        [IO.File]::ReadAllText($script:moved) | Should -BeExactly "2026-11-12 10:15:30  old line`r`n"
    }

    It 'replaces no file and gives the cause when a log of the new name exists already' {
        # The cause comes from the system's own error, so the module must know which system it is on.
        Mock -ModuleName PortableVM Test-PvmWindowsHost { $script:onWindows }
        [IO.File]::WriteAllText($script:log, "2026-11-12 10:15:30  old line`r`n")
        [IO.File]::WriteAllText($script:moved, 'earlier')
        $result = Move-PvmOldLog -Path $script:log -Time $script:time
        $result.Name | Should -BeExactly ''
        $result.Problem | Should -BeExactly 'an item of that name exists already'
        [IO.File]::ReadAllLines($script:log)[0] | Should -BeExactly '2026-11-12 10:15:30  old line'
        [IO.File]::ReadAllText($script:moved) | Should -BeExactly 'earlier'
    }

    # Only Windows keeps an open file from being moved; elsewhere the move goes through.
    It 'replaces no file and gives the cause when a program holds the log' -Tag 'WindowsOnly' {
        [IO.File]::WriteAllText($script:log, "2026-11-12 10:15:30  old line`r`n")
        $holder = [IO.File]::Open($script:log, 'Open', 'Read', 'ReadWrite')
        try {
            $result = Move-PvmOldLog -Path $script:log -Time $script:time
            # A program that shares writing holds back the move, not the log's next line.
            Write-PvmLog -Path $script:log -Message 'still written'
        } finally {
            $holder.Dispose()
        }
        $result.Name | Should -BeExactly ''
        $result.Problem | Should -BeExactly 'it is open in another program'
        [IO.File]::ReadAllLines($script:log)[0] | Should -BeExactly '2026-11-12 10:15:30  old line'
        Get-PvmLogProblem | Should -BeExactly ''
        [IO.File]::ReadAllLines($script:log)[-1] | Should -BeLike '*  still written'
    }

    Context 'in a run' -Tag 'WindowsOnly' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'rotation-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware'
            Mock -ModuleName PortableVM Get-PvmNow { [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(1)) }
            $null = New-Item -ItemType Directory -Path (Split-Path $script:stick.Log) -Force
            # A full log in the format: a line of an earlier run, then padding up to 1 MiB.
            $bytes = New-Object byte[] 1MB
            $script:oldHead = (Format-PvmLogText -Time ([DateTimeOffset]::new(2026, 11, 11, 9, 0, 0, 0, [TimeSpan]::FromHours(1))) -ProcessId 7 -Message 'an earlier run') + "`r`n"
            $head = [Text.Encoding]::ASCII.GetBytes($script:oldHead)
            [Array]::Copy($head, $bytes, $head.Length)
            [IO.File]::WriteAllBytes($script:stick.Log, $bytes)
            $script:oldHash = (Get-FileHash -LiteralPath $script:stick.Log -Algorithm SHA256).Hash
            $script:movedLog = Join-Path (Split-Path $script:stick.Log) 'launcher-20261112-101530.log'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'moves a full log aside before its first line and says where the earlier lines are' {
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 0
            (Get-FileHash -LiteralPath $script:movedLog -Algorithm SHA256).Hash | Should -BeExactly $script:oldHash
            (Get-TestLog -Path $script:stick.Log)[0..2] | Should -BeExactly @(
                '----- Start VM -----', 'Launcher version unknown', 'Note: the earlier lines of the log are in launcher-20261112-101530.log.')
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        }

        It 'moves nothing in a run that does not hold the lock: <Case>' -ForEach @(
            @{ Case = 'another run holds it'; Admin = $true; State = 'Busy' }
            @{ Case = 'no administrator rights'; Admin = $false; State = 'Acquired' }
        ) {
            $script:admin = $Admin
            $script:state = $State
            Mock -ModuleName PortableVM Invoke-PvmTestAdministrator { $script:admin }
            Mock -ModuleName PortableVM Invoke-PvmEnterLock { [pscustomobject]@{ State = $script:state; Mutex = $null } }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).ExitCode | Should -Be 1
            $script:movedLog | Should -Not -Exist
            # The earlier run's line still comes first.
            [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($script:stick.Log), 0, $script:oldHead.Length) | Should -BeExactly $script:oldHead
        }

        It 'says so and adds to the log when it cannot move it aside' {
            $holder = [IO.File]::Open($script:stick.Log, 'Open', 'Read', 'ReadWrite')
            try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher }
            finally { $holder.Dispose() }
            $result.ExitCode | Should -Be 0
            $script:movedLog | Should -Not -Exist
            (Get-TestAnsiEncoding).GetString([IO.File]::ReadAllBytes($script:stick.Log)) |
                Should -BeLike '*  Note: the log could not be moved aside, because it is open in another program; this run adds to it.*'
            Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        }
    }
}

Describe 'Log failures' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:stick = Initialize-TestStick -Name 'log-stick'
        Set-TestPc -Stick $script:stick -Installed 'VMware'
        $script:blocker = $null
    }
    AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

    It 'stops before it reads the PC when the log cannot be written: <Case>' -ForEach @(
        @{ Case = 'a program holds it'; Because = 'it is open in another program'; Hold = $true; Setup = {} }
        @{ Case = 'a file is named logs'; Because = 'LauncherData\logs is a file, not a folder'; Hold = $false; Setup = {
                [IO.File]::WriteAllText((Split-Path $script:stick.Log), 'not a folder')
            }
        }
        @{ Case = 'a folder is named launcher.log'; Because = 'it is a folder, not a file'; Hold = $false; Setup = {
                $null = New-Item -ItemType Directory -Path $script:stick.Log -Force
            }
        }
        @{ Case = 'an error the launcher has no words for'; Because = 'of an error of type IOException'; Hold = $true; Setup = {
                Mock -ModuleName PortableVM Get-PvmPathCause { 'an error of type IOException' }
            }
        }
    ) {
        $holder = $null
        if ($Hold) {
            $null = New-Item -ItemType Directory -Path (Split-Path $script:stick.Log) -Force
            [IO.File]::WriteAllText($script:stick.Log, '')
            $holder = [IO.File]::Open($script:stick.Log, 'Open', 'Read', 'Read')
        }
        & $Setup
        try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher }
        finally { if ($holder) { $holder.Dispose() } }
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeExactly "The launcher cannot write its log, LauncherData\logs\launcher.log, because $Because. Nothing was started."
        Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-PvmExitLock -ModuleName PortableVM -Times 1 -Exactly
    }

    It 'takes the same decision when the log fails later, and adds that the log is incomplete' {
        Mock -ModuleName PortableVM Invoke-PvmGetDisk {
            $script:blocker = [IO.File]::Open($script:stick.Log, 'Open', 'Read', 'Read')
            Get-TestDisk -Change @{ Signature = [uint32]0x5CA1AB1F }
        } -ParameterFilter { $Number -eq 3 }
        try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher }
        finally { if ($script:blocker) { $script:blocker.Dispose() } }
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeExactly ("This is not the expected USB stick (disk ID 5CA1AB1F, expected 5CA1AB1E). Nothing was started.`n`n" +
            'The launcher could not write all of this run to its log, LauncherData\logs\launcher.log, because it is open in another program.')
        $result.Icon | Should -BeExactly 'Error'
    }

    It 'starts, and warns that the log is incomplete, when the log fails later' {
        Mock -ModuleName PortableVM Invoke-PvmGetDisk {
            $script:blocker = [IO.File]::Open($script:stick.Log, 'Open', 'Read', 'Read')
            Get-TestDisk
        } -ParameterFilter { $Number -eq 3 }
        try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher }
        finally { if ($script:blocker) { $script:blocker.Dispose() } }
        Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        $result.ExitCode | Should -Be 0
        $result.Message | Should -BeExactly "The VM was started.`n`nThe launcher could not write all of this run to its log, LauncherData\logs\launcher.log, because it is open in another program."
        $result.Icon | Should -BeExactly 'Warning'
    }

    It 'says that a dry run found no stop, and warns that the log is incomplete, when the log fails later' {
        Mock -ModuleName PortableVM Invoke-PvmGetDisk {
            $script:blocker = [IO.File]::Open($script:stick.Log, 'Open', 'Read', 'Read')
            Get-TestDisk
        } -ParameterFilter { $Number -eq 3 }
        try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun }
        finally { if ($script:blocker) { $script:blocker.Dispose() } }
        Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 0 -Exactly
        $result.ExitCode | Should -Be 0
        $result.Message | Should -BeExactly "The dry run found nothing that would stop a start.`n`nThe launcher could not write all of this run to its log, LauncherData\logs\launcher.log, because it is open in another program."
        $result.Icon | Should -BeExactly 'Warning'
    }
}

Describe 'Single instance' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:stick = Initialize-TestStick -Name 'lock-stick'
        Set-TestPc -Stick $script:stick -Installed 'VMware'
    }
    AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

    It 'takes the lock by its name before the log has a line' {
        $script:logBefore = $null
        Mock -ModuleName PortableVM Invoke-PvmEnterLock {
            $script:logBefore = Test-Path -LiteralPath $script:stick.Log
            [pscustomobject]@{ State = 'Acquired'; Mutex = $null }
        }
        $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
        Should -Invoke -CommandName Invoke-PvmEnterLock -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Name -ceq 'Global\PortableVM-Launcher' }
        $script:logBefore | Should -BeFalse
    }

    It 'releases the lock once, after the End line: <Case>' -ForEach @(
        @{ Case = 'a start'; Dry = $false; Setup = {} }
        @{ Case = 'a stop'; Dry = $false; Setup = { Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk -Change @{ Signature = [uint32]0x5CA1AB1F } } -ParameterFilter { $Number -eq 3 } } }
        @{ Case = 'an unexpected error'; Dry = $false; Setup = { Mock -ModuleName PortableVM Invoke-PvmGetDisk { throw 'boom' } -ParameterFilter { $Number -eq 3 } } }
        @{ Case = 'a VM that runs already'; Dry = $false; Setup = { $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = "vmware-vmx.exe `"$($script:stick.Vmx)`"" }) } }
        @{ Case = 'a dry run'; Dry = $true; Setup = {} }
    ) {
        & $Setup
        $script:releases = @()
        Mock -ModuleName PortableVM Invoke-PvmExitLock { $script:releases += @((Get-TestLog -Path $script:stick.Log)[-1]) }
        $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$Dry
        $script:releases.Count | Should -Be 1
        $script:releases[0] | Should -BeLike '----- End*: exit code ? -----'
    }

    It 'notes after the End line when it cannot release the lock, and keeps the result' {
        Mock -ModuleName PortableVM Invoke-PvmExitLock { throw 'no release' }
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
        $result.ExitCode | Should -Be 0
        $result.Message | Should -BeExactly ''
        $result.Icon | Should -BeExactly ''
        $log = Get-TestLog -Path $script:stick.Log
        $log[-2] | Should -BeExactly '----- End: exit code 0 -----'
        $log[-1] | Should -BeExactly 'Note: the launcher could not release its lock (no release); Windows releases it when this process ends.'
        Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
    }

    It 'keeps the lock while it asks whether to resume' {
        Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"')
        $script:released = $false
        $script:releasedWhileAsking = $null
        Mock -ModuleName PortableVM Invoke-PvmExitLock { $script:released = $true }
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $script:releasedWhileAsking = $script:released; $true }
        $result.ExitCode | Should -Be 0
        $script:releasedWhileAsking | Should -BeFalse
        $script:released | Should -BeTrue
    }

    It 'stops at once while another run holds the lock, reading nothing: dry run <Dry>' -ForEach @(@{ Dry = $false }, @{ Dry = $true }) {
        Mock -ModuleName PortableVM Invoke-PvmEnterLock { [pscustomobject]@{ State = 'Busy'; Mutex = $null } }
        Mock -ModuleName PortableVM Import-PvmSetting { throw 'The settings must not be read.' }
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$Dry
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeExactly (Get-PvmBusyMessage)
        $result.Icon | Should -BeExactly 'Error'
        $result.Caption | Should -BeExactly 'Portable VM'
        $run = if ($Dry) { ' (dry run)' } else { '' }
        Get-TestLog -Path $script:stick.Log | Should -BeExactly @("----- Start VM$run -----", 'Launcher version unknown', "STOPPED: $(Get-PvmBusyMessage)", "----- End$($run): exit code 1 -----")
        Should -Invoke -CommandName Invoke-PvmExitLock -ModuleName PortableVM -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
        Should -Invoke -CommandName Import-PvmSetting -ModuleName PortableVM -Times 0 -Exactly
    }

    It 'takes over a lock that an earlier run left, and says so' {
        Mock -ModuleName PortableVM Invoke-PvmEnterLock { [pscustomobject]@{ State = 'Abandoned'; Mutex = $null } }
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
        $result.ExitCode | Should -Be 0
        (Get-TestLog -Path $script:stick.Log)[2] | Should -BeExactly 'Note: an earlier run of the launcher ended without releasing its lock; this run took the lock over.'
        Should -Invoke -CommandName Invoke-PvmStartProcess -ModuleName PortableVM -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-PvmExitLock -ModuleName PortableVM -Times 1 -Exactly
    }

    It 'stops without administrator rights before it takes the lock: dry run <Dry>' -ForEach @(
        @{ Dry = $false; Message = 'The launcher needs administrator rights, because the VM boots this USB stick directly.' }
        @{ Dry = $true; Message = 'A dry run needs administrator rights, as a real start has them, so that its checks see what a real start sees. Run it from an elevated PowerShell. Nothing was started.' }
    ) {
        Mock -ModuleName PortableVM Invoke-PvmTestAdministrator { $false }
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$Dry
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeExactly $Message
        $run = if ($Dry) { ' (dry run)' } else { '' }
        Get-TestLog -Path $script:stick.Log | Should -BeExactly @("----- Start VM$run -----", 'Launcher version unknown', "STOPPED: $Message", "----- End$($run): exit code 1 -----")
        Should -Invoke -CommandName Invoke-PvmEnterLock -ModuleName PortableVM -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
    }
}

Describe 'The lock''s mutex' -Tag 'WindowsOnly' {
    BeforeAll {
        # Run $Script with $Arguments in a runspace of its own on a new thread, wait for it and
        # return its output. Disposing the runspace ends that thread.
        function Invoke-TestOnOtherThread {
            param([scriptblock]$Script, [object[]]$Arguments)
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.ThreadOptions = 'UseNewThread'
            $runspace.Open()
            $shell = [PowerShell]::Create()
            $shell.Runspace = $runspace
            try {
                $null = $shell.AddScript($Script.ToString())
                foreach ($argument in $Arguments) { $null = $shell.AddArgument($argument) }
                $shell.Invoke()
            } finally {
                $shell.Dispose()
                $runspace.Dispose()
            }
        }
    }

    # Only unique Local\ names, never the launcher's own lock.
    BeforeEach { $script:name = "Local\PortableVM-Test-$([guid]::NewGuid())" }

    It 'is taken when it is free, and free for another thread after its release' {
        $lock = Enter-PvmMutex -Name $script:name
        $lock.State | Should -BeExactly 'Acquired'
        $lock.Mutex | Should -BeOfType ([System.Threading.Mutex])
        # A second handle keeps the mutex while the lock's own handle closes.
        $keep = [System.Threading.Mutex]::OpenExisting($script:name)
        try {
            Exit-PvmMutex -Lock $lock
            $free = Invoke-TestOnOtherThread -Arguments $script:name -Script {
                param($Name)
                $mutex = [System.Threading.Mutex]::OpenExisting($Name)
                try {
                    $taken = $mutex.WaitOne(0)
                    if ($taken) { $mutex.ReleaseMutex() }
                    $taken
                } finally {
                    $mutex.Dispose()
                }
            }
        } finally {
            $keep.Dispose()
        }
        $free | Should -BeTrue
    }

    It 'is busy while another thread holds it' {
        $ready = [System.Threading.ManualResetEvent]::new($false)
        $done = [System.Threading.ManualResetEvent]::new($false)
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ThreadOptions = 'UseNewThread'
        $runspace.Open()
        $shell = [PowerShell]::Create()
        $shell.Runspace = $runspace
        try {
            $holder = {
                param($Name, $Ready, $Done)
                $mutex = [System.Threading.Mutex]::new($false, $Name)
                $null = $mutex.WaitOne()
                $null = $Ready.Set()
                $null = $Done.WaitOne(10000)
                $mutex.ReleaseMutex()
                $mutex.Dispose()
            }
            $null = $shell.AddScript($holder.ToString()).AddArgument($script:name).AddArgument($ready).AddArgument($done)
            $async = $shell.BeginInvoke()
            $ready.WaitOne(10000) | Should -BeTrue
            $lock = Enter-PvmMutex -Name $script:name
            $lock.State | Should -BeExactly 'Busy'
            $lock.Mutex | Should -BeNullOrEmpty
        } finally {
            $null = $done.Set()
            if ($async) { $null = $shell.EndInvoke($async) }
            $shell.Dispose()
            $runspace.Dispose()
            $ready.Dispose()
            $done.Dispose()
        }
    }

    It 'is busy when this process may not open it, as when an elevated run holds it' {
        $holder = New-TestDeniedMutex -Name $script:name
        try {
            $lock = Enter-PvmMutex -Name $script:name
            $lock.State | Should -BeExactly 'Busy'
            $lock.Mutex | Should -BeNullOrEmpty
        } finally {
            $holder.Dispose()
        }
    }

    It 'fails, rather than report busy, when an object of another kind holds its name' {
        $squatter = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $script:name)
        try {
            $thrown = $null
            try { $null = Enter-PvmMutex -Name $script:name } catch { $thrown = $_ }
            $thrown | Should -Not -BeNullOrEmpty
            $exception = $thrown.Exception
            while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
            $exception | Should -BeOfType ([System.Threading.WaitHandleCannotBeOpenedException])
        } finally {
            $squatter.Dispose()
        }
    }

    It 'is taken over when its holder ended without releasing it' {
        # The test's own handle keeps the mutex, which Windows then marks abandoned.
        $keep = [System.Threading.Mutex]::new($false, $script:name)
        try {
            $null = Invoke-TestOnOtherThread -Arguments $script:name -Script {
                param($Name)
                $mutex = [System.Threading.Mutex]::new($false, $Name)
                $null = $mutex.WaitOne()
            }
            # Windows marks the mutex abandoned once the holder's thread has ended, which can come
            # a moment after the runspace is gone on a busy PC.
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                $lock = Enter-PvmMutex -Name $script:name
                if ($lock.State -eq 'Busy') { Start-Sleep -Milliseconds 20 }
            } while ($lock.State -eq 'Busy' -and [DateTime]::UtcNow -lt $deadline)
            $lock.State | Should -BeExactly 'Abandoned'
            { Exit-PvmMutex -Lock $lock } | Should -Not -Throw
        } finally {
            $keep.Dispose()
        }
    }
}

Describe 'Unexpected errors' -Tag 'WindowsOnly' {
    BeforeEach {
        $script:stick = Initialize-TestStick -Name 'error-stick'
        Set-TestPc -Stick $script:stick -Installed 'VMware', 'VirtualBox'
        $script:ask = { $true }
    }
    AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

    It 'name the step they happened in: <Text>' -ForEach @(
        @{ Text = 'starting the launcher'; Releases = 0; Setup = { Mock -ModuleName PortableVM Invoke-PvmEnterLock { throw 'boom' } } }
        @{ Text = 'starting the launcher'; Releases = 0; Setup = { Mock -ModuleName PortableVM Invoke-PvmTestAdministrator { throw 'boom' } } }
        @{ Text = 'reading the settings'; Releases = 1; Setup = { Mock -ModuleName PortableVM Import-PvmSetting { throw 'boom' } } }
        @{ Text = 'finding the stick'; Releases = 1; Setup = { Mock -ModuleName PortableVM Invoke-PvmGetDisk { throw 'boom' } -ParameterFilter { $Number -eq 3 } } }
        # Only the error of a missing drive letter becomes a stop; another error of Get-Partition does not.
        @{ Text = 'finding the stick'; Releases = 1; Setup = {
                Mock -ModuleName PortableVM Invoke-PvmGetPartition {
                    throw ([System.Management.Automation.ErrorRecord]::new([Exception]::new('boom'), 'CmdletizationQuery_NotFound_DiskNumber,Get-Partition', 'ObjectNotFound', $null))
                } -ParameterFilter { $DriveLetter -ceq $script:stick.Letter }
            }
        }
        @{ Text = 'checking this PC and the saved states'; Releases = 1; Setup = { Mock -ModuleName PortableVM Invoke-PvmGetDeviceGuard { throw 'boom' } } }
        @{ Text = 'checking for running VMs'; Releases = 1; Setup = { Mock -ModuleName PortableVM Invoke-PvmGetProcess { throw 'boom' } } }
        @{ Text = 'asking whether to resume the saved state'; Releases = 1; Setup = {
                Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"')
                $script:ask = { throw 'boom' }
            }
        }
        @{ Text = "waiting for VirtualBox's background service to end"; Releases = 1; Setup = {
                $script:testInstalled = @('VirtualBox')
                Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true } -ParameterFilter { $Name -eq 'VBoxSVC' }
                Mock -ModuleName PortableVM Wait-PvmProcessExit { throw 'boom' }
            }
        }
        @{ Text = 'pointing the VM files at the stick'; Releases = 1; Setup = { Mock -ModuleName PortableVM Save-PvmFirstCopy { throw 'boom' } } }
        @{ Text = 'starting the VM'; Releases = 1; Setup = { Mock -ModuleName PortableVM Invoke-PvmStartProcess { throw 'boom' } } }
        @{ Text = 'starting the VM'; Releases = 1; Setup = {
                $script:testInstalled = @('VirtualBox')
                Mock -ModuleName PortableVM Invoke-PvmNative { throw 'boom' } -ParameterFilter { $ArgumentList[0] -eq 'list' }
            }
        }
    ) {
        & $Setup
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume $script:ask
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeExactly "Unexpected error while ${Text}: boom"
        $result.Icon | Should -BeExactly 'Error'
        $log = Get-TestLog -Path $script:stick.Log
        # Every run begins with its start and version lines, a run that fails in its setup too.
        $log[0] | Should -BeExactly '----- Start VM -----'
        $log[1] | Should -BeExactly 'Launcher version unknown'
        $log | Should -Contain "STOPPED: Unexpected error while ${Text}: boom"
        $detail = @($log | Where-Object { $_.StartsWith('Error detail: ') })
        $detail.Count | Should -BeGreaterOrEqual 1
        @($detail | Where-Object { $_.EndsWith('Exception: boom') }).Count | Should -BeGreaterOrEqual 1
        @($log | Where-Object { $_.StartsWith('Error ID: ') }).Count | Should -Be 1
        $traces = @($log | Where-Object { $_.StartsWith('Error trace: ') }).Count
        $traces | Should -BeGreaterOrEqual 1
        $traces | Should -BeLessOrEqual 10
        $log[-1] | Should -BeExactly '----- End: exit code 1 -----'
        Should -Invoke -CommandName Invoke-PvmExitLock -ModuleName PortableVM -Times $Releases -Exactly
    }

    It 'are described by at most four of their exceptions, each on one line' {
        $exception = [Exception]::new('level 5')
        foreach ($level in 4, 3, 2) { $exception = [Exception]::new("level $level", $exception) }
        $exception = [Exception]::new("level 1`r`n  second line", $exception)
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'Test', 'NotSpecified', $null)
        @(Format-PvmErrorDetail -ErrorRecord $record) | Should -BeExactly @(
            'Error detail: System.Exception: level 1 second line', 'Error detail: System.Exception: level 2',
            'Error detail: System.Exception: level 3', 'Error detail: System.Exception: level 4', 'Error ID: Test')
    }

    It 'name the innermost error of a .NET method, and log the ones around it' {
        $script:missing = Join-Path $TestDrive 'none\x.txt'
        Mock -ModuleName PortableVM Invoke-PvmGetDisk { [IO.File]::ReadAllText($script:missing) } -ParameterFilter { $Number -eq 3 }
        $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
        $result.Message | Should -BeLike 'Unexpected error while finding the stick: *'
        $result.Message | Should -Not -BeLike '*ReadAllText*'
        $result.Message.Contains((Split-Path $script:missing)) | Should -BeTrue
        $detail = @(Get-TestLog -Path $script:stick.Log | Where-Object { $_.StartsWith('Error detail: ') })
        $detail[0] | Should -BeLike 'Error detail: System.Management.Automation.MethodInvocationException: *'
        $detail[1] | Should -BeLike 'Error detail: System.IO.DirectoryNotFoundException: *'
    }

    It 'leave a stop as it is, adding the system''s message about a settings file that cannot be opened' {
        $holder = [IO.File]::Open($script:stick.Settings, 'Open', 'Read', 'None')
        try { $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher }
        finally { $holder.Dispose() }
        $result.Message | Should -BeExactly "LauncherData\settings.psd1 cannot be read: it is open in another program.`n`nNothing was started."
        $log = Get-TestLog -Path $script:stick.Log
        $log[-2].StartsWith('Error detail: ') | Should -BeTrue
        $log[-2].Contains($script:stick.Settings) | Should -BeTrue
        @($log | Where-Object { $_.StartsWith('Error ID: ') }).Count | Should -Be 0
    }
}

Describe 'The drive letter' {
    It 'is the root of a path with a drive letter, in upper case: <Path>' -Tag 'WindowsOnly' -ForEach @(
        @{ Path = 'X:\Launcher'; Letter = 'X' }
        @{ Path = 'x:\Folder\Launcher'; Letter = 'X' }
        @{ Path = '\\server\share\Launcher'; Letter = $null }
        @{ Path = '\\?\X:\Launcher'; Letter = $null }
        @{ Path = '\\.\X:\Launcher'; Letter = $null }
        @{ Path = 'X:Launcher'; Letter = $null }
    ) {
        # String work only; no such path reaches Invoke-PortableVM.
        Get-PvmDriveLetter -Path $Path | Should -BeExactly $Letter
    }

    Context 'in a run' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'letter-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'stops when the launcher does not run from a drive letter' -Tag 'WindowsOnly' {
            Mock -ModuleName PortableVM Get-PvmDriveLetter { $null }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "The launcher runs from $($script:stick.Launcher), which is not on a drive with a letter, so it cannot tell which disk is the USB stick. Start it with Start VM.cmd on the stick's own drive. Nothing was started."
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops when no partition has the drive letter' {
            Mock -ModuleName PortableVM Invoke-PvmGetPartition { throw (Get-TestNoPartitionError) } -ParameterFilter { $DriveLetter -ceq $script:stick.Letter }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly "Windows has no partition with the drive letter $($script:stick.Letter):, so the launcher cannot tell which disk is the USB stick; a network drive or a drive made with subst has none. Start it with Start VM.cmd on the stick's own drive. Nothing was started."
            Should -Invoke -CommandName Invoke-PvmGetDisk -ModuleName PortableVM -Times 0 -Exactly
        }

        It 'stops with the Windows message when Windows finds no location for the stick' {
            Mock -ModuleName PortableVM Get-PvmStickLocation { $null }
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $true }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly "The launcher runs from $($script:stick.Launcher), which is not on a drive with a letter, so it cannot tell which disk is the USB stick. Start it with Start VM.cmd on the stick's own drive. Nothing was started."
        }

        It 'stops before it reads a disk on a system where it cannot find the stick yet' {
            Mock -ModuleName PortableVM Get-PvmStickLocation { $null }
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $false }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly 'On this system the launcher cannot tell yet which disk is the USB stick; so far it starts the VM only on Windows. Nothing was started.'
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-PvmGetDisk -ModuleName PortableVM -Times 0 -Exactly
            (Get-TestLog -Path $script:stick.Log) | Should -Contain 'STOPPED: On this system the launcher cannot tell yet which disk is the USB stick; so far it starts the VM only on Windows. Nothing was started.'
        }

        It 'stops with the plain message before the rights check and the lock on a system other than Windows, where the rights check throws: dry run <DryRun>' -ForEach @(
            @{ DryRun = $false; Start = '----- Start VM -----'; End = '----- End: exit code 1 -----' }
            @{ DryRun = $true; Start = '----- Start VM (dry run) -----'; End = '----- End (dry run): exit code 1 -----' }
        ) {
            Mock -ModuleName PortableVM Test-PvmWindowsHost { $false }
            Mock -ModuleName PortableVM Invoke-PvmTestAdministrator { throw [PlatformNotSupportedException]::new('Windows Principal functionality is not supported on this platform.') }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$DryRun
            $stop = 'On this system the launcher cannot tell yet which disk is the USB stick; so far it starts the VM only on Windows. Nothing was started.'
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeExactly $stop
            $result.Icon | Should -BeExactly 'Error'
            Should -Invoke -CommandName Invoke-PvmTestAdministrator -ModuleName PortableVM -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-PvmEnterLock -ModuleName PortableVM -Times 0 -Exactly
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
            $log = Get-TestLog -Path $script:stick.Log
            $log | Should -BeExactly @($Start, 'Launcher version unknown', "STOPPED: $stop", $End)
        }
    }
}

Describe 'Timings' {
    It 'list each step in milliseconds, and the total' {
        Format-PvmTiming -Times ([ordered]@{ setup = 14; settings = 31; stick = 1409 }) | Should -BeExactly 'Timings: setup 14 ms, settings 31 ms, stick 1409 ms, total 1454 ms'
    }

    It 'add up the time of a step entered again, with the clock restarted for each step' {
        # A clock that only moves when the test says so, and that Restart sets back to 0.
        $clock = [pscustomobject]@{ ElapsedMilliseconds = [int64]0 }
        $clock | Add-Member -MemberType ScriptMethod -Name Restart -Value { $this.ElapsedMilliseconds = [int64]0 }
        $context = [pscustomobject]@{ Step = 'setup'; Clock = $clock; Times = [ordered]@{} }
        foreach ($stretch in @(@{ Spent = 5; Next = 'a' }, @{ Spent = 7; Next = 'b' }, @{ Spent = 11; Next = 'a' }, @{ Spent = 13; Next = '' })) {
            $clock.ElapsedMilliseconds += $stretch.Spent
            Enter-PvmStep -Context $context -Name $stretch.Next
        }
        $context.Step | Should -BeExactly ''
        Format-PvmTiming -Times $context.Times | Should -BeExactly 'Timings: setup 5 ms, a 20 ms, b 11 ms, total 36 ms'
    }

    Context 'in a run' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'timing-stick'
            Set-TestPc -Stick $script:stick -Installed 'VMware', 'VirtualBox'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'come before the End line of a start in VMware' {
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $log = Get-TestLog -Path $script:stick.Log -Timings
            $log[-2] | Should -Match '^Timings: setup \d+ ms, settings \d+ ms, stick \d+ ms, choice \d+ ms, checks \d+ ms, files \d+ ms, start \d+ ms, total \d+ ms$'
            $log[-1] | Should -BeExactly '----- End: exit code 0 -----'
        }

        It 'show the wait and the question of a start in VirtualBox' {
            $script:stick = Initialize-TestStick -Name 'timing-stick' -Change @{ Hypervisor = 'VirtualBox' }
            [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            $script:svc = 0
            Mock -ModuleName PortableVM Invoke-PvmTestProcess { $script:svc++ -lt 1 } -ParameterFilter { $Name -eq 'VBoxSVC' }
            Mock -ModuleName PortableVM Wait-PvmProcessExit {}
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher -AskResume { $true }).ExitCode | Should -Be 0
            (Get-TestLog -Path $script:stick.Log -Timings)[-2] |
                Should -Match '^Timings: setup \d+ ms, settings \d+ ms, stick \d+ ms, choice \d+ ms, checks \d+ ms, wait \d+ ms, question \d+ ms, files \d+ ms, start \d+ ms, total \d+ ms$'
        }

        It 'end with the stick on a stop on another disk' {
            Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk -Change @{ Signature = [uint32]0x5CA1AB1F } } -ParameterFilter { $Number -eq 3 }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            (Get-TestLog -Path $script:stick.Log -Timings)[-2] | Should -Match '^Timings: setup \d+ ms, settings \d+ ms, stick \d+ ms, total \d+ ms$'
        }
    }
}

Describe 'Dry-run parity' {
    It 'takes the decisions of a real start: <Case>' -ForEach @(
        @{ Case = 'VMware, nothing in the way'; Installed = @('VMware'); Change = @{}; Setup = {} }
        @{ Case = 'VirtualBox, nothing in the way'; Installed = @('VirtualBox'); Change = @{}; Setup = {} }
        @{ Case = 'VirtualBox with HideDataPartition'; Installed = @('VirtualBox'); Change = @{ HideDataPartition = $true }; Setup = {} }
        @{ Case = 'VMware without its descriptor'; Installed = @('VMware'); Change = @{}; Setup = { Remove-Item -LiteralPath $script:stick.VMwareDisk } }
        @{ Case = 'VMware with the VM running in VMware'; Installed = @('VMware'); Change = @{}; Setup = { $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = "vmware-vmx.exe `"$($script:stick.Vmx)`"" }) } }
        @{ Case = 'VMware while a VirtualBox VM may be this one'; Installed = @('VMware'); Change = @{}; Setup = { $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBoxVM.exe'; CommandLine = $null }) } }
        @{ Case = 'VMware chosen with a VirtualBox save'; Installed = @('VMware', 'VirtualBox'); Change = @{ Hypervisor = 'VMware' }; Setup = {
                [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            }
        }
        @{ Case = 'VMware .vmx without suspend.disabled'; Installed = @('VMware'); Change = @{}; Setup = { Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Without 'suspend.disabled') } }
        # A dry run carries on past its first stop, here to a later one; it returns the first.
        @{ Case = 'VMware .vmx without suspend.disabled, and a descriptor without an extent'; Installed = @('VMware'); Change = @{}; Setup = {
                Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Without 'suspend.disabled')
                Write-TestFile -Path $script:stick.VMwareDisk -Text 'createType="fullDevice"'
            }
        }
        @{ Case = 'VMware suspend answered Yes'; Installed = @('VMware'); Change = @{}; Setup = { Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"') } }
        @{ Case = 'VMware suspend with SavedStatePolicy Refuse'; Installed = @('VMware'); Change = @{ SavedStatePolicy = 'Refuse' }; Setup = { Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"') } }
        @{ Case = 'VirtualBox save answered Yes'; Installed = @('VirtualBox'); Change = @{}; Setup = {
                [IO.File]::WriteAllText($script:stick.Vbox, [IO.File]::ReadAllText($script:stick.Vbox).Replace('OSType="Debian_64"', 'OSType="Debian_64" stateFile="Snapshots\x.sav"'))
            }
        }
        @{ Case = 'VirtualBox while the VM runs in VMware'; Installed = @('VirtualBox'); Change = @{}; Setup = { $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = $null }) } }
        @{ Case = 'VirtualBox while the VM is suspended in VMware'; Installed = @('VirtualBox'); Change = @{}; Setup = { Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"') } }
        @{ Case = 'VirtualBox open with another VM'; Installed = @('VirtualBox'); Change = @{}; Setup = { $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null }) } }
        @{ Case = 'VirtualBox open and the VM running'; Installed = @('VirtualBox'); Change = @{}; Setup = {
                $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
                Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = 'VMState="running"' } } -ParameterFilter { $ArgumentList[0] -eq 'showvminfo' }
            }
        }
        # A dry run carries on past its first stop, here to a VM that runs already; it returns the stop.
        @{ Case = 'VirtualBox while the VM is suspended in VMware, and VirtualBox open with the VM running'; Installed = @('VirtualBox'); Change = @{}; Setup = {
                Write-TestFile -Path $script:stick.Vmx -Text (Get-TestVmxText -Add 'checkpoint.vmState = "Test VM.vmss"')
                $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
                Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = 'VMState="running"' } } -ParameterFilter { $ArgumentList[0] -eq 'showvminfo' }
            }
        }
        @{ Case = 'VBoxSVC ending during the wait'; Installed = @('VirtualBox'); Change = @{}; Setup = {
                $script:svc = 0
                Mock -ModuleName PortableVM Invoke-PvmTestProcess { $script:svc++ -lt 2 } -ParameterFilter { $Name -eq 'VBoxSVC' }
            }
        }
        @{ Case = 'VBoxSVC still running after the wait'; Installed = @('VirtualBox'); Change = @{}; Setup = {
                Mock -ModuleName PortableVM Wait-PvmProcessExit { $script:waits++ }
                Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true } -ParameterFilter { $Name -eq 'VBoxSVC' }
            }
        }
        @{ Case = 'VirtualBox open and VBoxSVC still running'; Installed = @('VirtualBox'); Change = @{}; Setup = {
                $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
                Mock -ModuleName PortableVM Wait-PvmProcessExit { $script:waits++ }
                Mock -ModuleName PortableVM Invoke-PvmTestProcess { $true } -ParameterFilter { $Name -eq 'VBoxSVC' }
            }
        }
        @{ Case = 'another run holding the lock'; Installed = @('VMware'); Change = @{}; Setup = { Mock -ModuleName PortableVM Invoke-PvmEnterLock { [pscustomobject]@{ State = 'Busy'; Mutex = $null } } } }
        @{ Case = 'a lock that an earlier run left'; Installed = @('VMware'); Change = @{}; Setup = { Mock -ModuleName PortableVM Invoke-PvmEnterLock { [pscustomobject]@{ State = 'Abandoned'; Mutex = $null } } } }
        @{ Case = 'another disk'; Installed = @('VMware'); Change = @{}; Setup = { Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk -Change @{ Signature = [uint32]0x5CA1AB1F } } -ParameterFilter { $Number -eq 3 } } }
        @{ Case = 'settings with problems'; Installed = @('VMware'); Change = @{ Hypervisor = 'VBox' }; Setup = {} }
        @{ Case = 'neither hypervisor installed'; Installed = @(); Change = @{}; Setup = {} }
        @{ Case = 'a .vbox that is no XML'; Installed = @('VMware', 'VirtualBox'); Change = @{}; Setup = { Write-TestFile -Path $script:stick.Vbox -Text 'no XML' } }
        @{ Case = 'no partition with the drive letter'; Installed = @('VMware'); Change = @{}; Setup = {
                Mock -ModuleName PortableVM Invoke-PvmGetPartition { throw (Get-TestNoPartitionError) } -ParameterFilter { $DriveLetter -ceq $script:stick.Letter }
            }
        }
    ) {
        $runs = foreach ($dry in $false, $true) {
            # The same path both times, so that messages that name a path agree.
            $script:stick = Initialize-TestStick -Name 'parity-stick' -Change $Change
            Set-TestPc -Stick $script:stick -Installed $Installed
            $script:starts = 0
            $script:startvms = 0
            $script:waits = 0
            Mock -ModuleName PortableVM Invoke-PvmStartProcess { $script:starts++ }
            Mock -ModuleName PortableVM Invoke-PvmNative { $script:startvms++; [pscustomobject]@{ ExitCode = 0; Output = 'VM has been successfully started.' } } -ParameterFilter { $ArgumentList[0] -eq 'startvm' }
            & $Setup
            $before = Get-TestTreeHash -Root $script:stick.Root
            $ask = if ($dry) { { throw 'A dry run must not ask.' } } else { { $true } }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun:$dry -AskResume $ask
            $after = Get-TestTreeHash -Root $script:stick.Root
            $changed = ((@($after.Keys | Sort-Object) -join '|') -cne (@($before.Keys | Sort-Object) -join '|')) -or
                (@($before.Keys | Where-Object { $after[$_] -ne $before[$_] }).Count -gt 0)
            [pscustomobject]@{
                Result    = $result
                Decisions = @(ConvertTo-TestDecision -Lines (Get-TestLog -Path $script:stick.Log))
                Starts    = $script:starts
                StartVms  = $script:startvms
                Waits     = $script:waits
                Changed   = $changed
            }
            Remove-Item -LiteralPath $script:stick.Root -Recurse -Force
        }
        $real, $dryRun = $runs
        $dryRun.Result.ExitCode | Should -Be $real.Result.ExitCode
        $dryRun.Result.Message | Should -BeExactly $real.Result.Message
        $dryRun.Result.Icon | Should -BeExactly $real.Result.Icon
        $dryRun.Result.Caption | Should -BeExactly $real.Result.Caption
        $dryRun.Decisions | Should -BeExactly $real.Decisions
        $dryRun.Starts | Should -Be 0
        $dryRun.StartVms | Should -Be 0
        $dryRun.Changed | Should -BeFalse
        $dryRun.Waits | Should -Be $real.Waits
    }
}
