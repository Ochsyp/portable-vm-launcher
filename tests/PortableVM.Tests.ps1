# Characterisation tests of src\PortableVM.psm1: what the launcher decides, logs and writes, as it
# did before the redesign. The stick and the PC are synthetic: disks and partitions are
# PSCustomObjects, the stick's files live in TestDrive, every adapter is mocked, and
# $env:PVM_TEST makes an unmocked one throw. A test whose name says "known issue" pins behaviour
# that the phase it names changes.

BeforeAll {
    $script:previousTestFlag = $env:PVM_TEST
    $env:PVM_TEST = '1'
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force
    $script:utf8 = New-Object System.Text.UTF8Encoding $false
    $script:uuid = '5ca1ab1e-0000-4000-8000-000000000001'
    # The WQL filters of the launcher's process checks.
    $script:vmwareFilter = "Name='vmware-vmx.exe'"
    $script:virtualBoxVmFilter = "Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"
    $script:virtualBoxOpenFilter = "Name='VirtualBox.exe' OR Name='VirtualBoxVM.exe' OR Name='VBoxHeadless.exe'"

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

    # Return the settings of the synthetic stick, with the values in $Change replaced.
    function Get-TestSettingTable {
        param([hashtable]$Change = @{})
        $settings = @{
            Hypervisor = 'Auto'; VMwareView = 'Window'; HideDataPartition = $false
            StickMbrSignature = '5CA1AB1E'; StickSectors = 4000000; VmSectors = 3900000; DataPartitionStart = 2500000
            VirtualBoxVmUuid = $script:uuid; VirtualBoxHome = 'VirtualBox'
            VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'; VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'
            VMwareVmx = 'VMware\Test VM.vmx'; VMwareDisk = 'VMware\stick.vmdk'
        }
        foreach ($key in $Change.Keys) { $settings[$key] = $Change[$key] }
        $settings
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

    # Create a synthetic stick in TestDrive\$Name and return its paths. Launcher\settings.psd1 holds
    # Get-TestSettingTable with $Change applied, written as PowerShell data. The VMware folder holds
    # the .vmx and a CRLF descriptor; the VirtualBox home holds VirtualBox.xml and the VM with an LF
    # descriptor, and their paths on the stick carry the drive letter OldLetter. The two programs
    # are empty files below Programs.
    function Initialize-TestStick {
        param(
            [string]$Name = 'stick',
            [hashtable]$Change = @{}
        )
        $root = Join-Path $TestDrive $Name
        $stick = [pscustomobject]@{
            Root           = $root
            Launcher       = Join-Path $root 'Launcher'
            Log            = Join-Path $root 'Launcher\launcher.log'
            Vmx            = Join-Path $root 'VMware\Test VM.vmx'
            VMwareDisk     = Join-Path $root 'VMware\stick.vmdk'
            Vbox           = Join-Path $root 'VirtualBox\Test VM\Test VM.vbox'
            VirtualBoxXml  = Join-Path $root 'VirtualBox\VirtualBox.xml'
            VirtualBoxDisk = Join-Path $root 'VirtualBox\Test VM\stick.vmdk'
            VMwareDir      = Join-Path $root 'Programs\VMware'
            VirtualBoxDir  = Join-Path $root 'Programs\VirtualBox'
            Letter         = $root.Substring(0, 1).ToUpper()
            OldLetter      = if ($root.Substring(0, 1).ToUpper() -eq 'Q') { 'R' } else { 'Q' }
        }
        $settings = Get-TestSettingTable -Change $Change
        $lines = foreach ($key in ($settings.Keys | Sort-Object)) {
            $value = $settings[$key]
            $literal = if ($value -is [bool]) { "`$$value".ToLower() } elseif ($value -is [string]) { "'$value'" } else { "$value" }
            "    $key = $literal"
        }
        Write-TestFile -Path (Join-Path $stick.Launcher 'settings.psd1') -Text ("@{`r`n" + ($lines -join "`r`n") + "`r`n}`r`n")
        Write-TestFile -Path (Join-Path $stick.VMwareDir 'vmware.exe') -Text ''
        Write-TestFile -Path (Join-Path $stick.VirtualBoxDir 'VBoxManage.exe') -Text ''
        Write-TestFile -Path $stick.Vmx -Text (Get-TestVmxText)
        Write-TestFile -Path $stick.VMwareDisk -Text (Get-TestDescriptorText)
        Write-TestFile -Path $stick.VirtualBoxDisk -Text (Get-TestDescriptorText -Newline "`n")
        $below = $root.Substring(2)
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

    # Return the lines of the log $Path without their timestamps.
    function Get-TestLog {
        param([string]$Path)
        @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Substring(21) })
    }

    # Return a hashtable of every file below $Root, other than launcher.log, with its SHA-256 hash.
    function Get-TestTreeHash {
        param([string]$Root)
        $hashes = @{}
        foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ne 'launcher.log' }) {
            $hashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        $hashes
    }

    # Return the processes in $script:testProcesses whose names the WQL condition $Filter lists as
    # Name='<name>', as the launcher's process check would find them.
    function Get-TestProcess {
        param([string]$Filter)
        $names = @([regex]::Matches($Filter, "Name='([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        @($script:testProcesses | Where-Object { $names -ccontains $_.Name })
    }

    # Mock every adapter for a start on the synthetic stick $Stick: the partition with the stick's
    # letter is on disk 3, which is the stick; the processes in $script:testProcesses run, none at
    # first; and the hypervisors in $Installed ('VMware', 'VirtualBox') are installed. VBoxManage
    # lists the VM, reports it powered off and starts it.
    function Set-TestPc {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper that only defines mocks.')]
        param($Stick, [string[]]$Installed = @('VMware', 'VirtualBox'))
        $script:testStick = $Stick
        $script:testInstalled = $Installed
        $script:testProcesses = @()
        Mock -ModuleName PortableVM Write-Host {}
        Mock -ModuleName PortableVM Invoke-PvmGetPartition { throw "No partition has the drive letter $DriveLetter." }
        Mock -ModuleName PortableVM Invoke-PvmGetPartition { Get-TestPartition } -ParameterFilter { $DriveLetter -ceq $script:testStick.Letter }
        Mock -ModuleName PortableVM Invoke-PvmGetDisk { throw "No disk has the number $Number." }
        Mock -ModuleName PortableVM Invoke-PvmGetDisk { Get-TestDisk } -ParameterFilter { $Number -eq 3 }
        Mock -ModuleName PortableVM Invoke-PvmGetDeviceGuard { $null }
        Mock -ModuleName PortableVM Invoke-PvmGetProcess { Get-TestProcess -Filter $Filter }
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
        @{ Name = 'Invoke-PvmGetProcess'; Call = { Invoke-PvmGetProcess -Filter "Name='none.exe'" } }
        @{ Name = 'Invoke-PvmTestProcess'; Call = { Invoke-PvmTestProcess -Name 'none' } }
        @{ Name = 'Invoke-PvmGetDeviceGuard'; Call = { Invoke-PvmGetDeviceGuard } }
        @{ Name = 'Invoke-PvmGetRegistryValue'; Call = { Invoke-PvmGetRegistryValue -Path 'HKLM:\SOFTWARE\None' -Name 'None' } }
        @{ Name = 'Invoke-PvmNative'; Call = { Invoke-PvmNative -FilePath 'none.exe' } }
        @{ Name = 'Invoke-PvmStartProcess'; Call = { Invoke-PvmStartProcess -FilePath 'none.exe' -ArgumentList 'none' } }
        @{ Name = 'Invoke-PvmSetEnvironment'; Call = { Invoke-PvmSetEnvironment -Name 'PVM_NONE' -Value 'none' } }
        @{ Name = 'Invoke-PvmSleep'; Call = { Invoke-PvmSleep -Seconds 1 } }
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

    It 'write all new extents where the first old one was, in any case, and keep LF' {
        $text = "createType=`"x`"`nrw 10 flat `"a`" 0`nmiddle`nRDONLY 5 ZERO`nNOACCESS 2 FLAT `"b`" 0`nend"
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 17 FLAT "\\.\PhysicalDrive3" 0') }
        ConvertTo-PvmDescriptorText -Text $text -Layout $layout |
            Should -BeExactly "createType=`"fullDevice`"`nRW 17 FLAT `"\\.\PhysicalDrive3`" 0`nmiddle`nend"
    }

    It 'return nothing for a descriptor without a FLAT or ZERO extent, such as a sparse one' {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 17 FLAT "\\.\PhysicalDrive3" 0') }
        ConvertTo-PvmDescriptorText -Text "createType=`"monolithicSparse`"`nRW 17 SPARSE `"disk.vmdk`"" -Layout $layout | Should -BeNullOrEmpty
    }

    It 'add no createType line to a descriptor that has none (known issue, phase 5)' {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 17 FLAT "\\.\PhysicalDrive3" 0') }
        ConvertTo-PvmDescriptorText -Text "RW 9 FLAT `"x`" 0" -Layout $layout | Should -BeExactly 'RW 17 FLAT "\\.\PhysicalDrive3" 0'
    }

    It 'are created for VMware with a fixed IDE disk database and CRLF' {
        $layout = @{ CreateType = 'fullDevice'; Extents = @('RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO') }
        Get-PvmVMwareDescriptorText -Layout $layout | Should -BeExactly (@('# Disk DescriptorFile', 'version=1', 'encoding="windows-1252"',
                'CID=fffffffe', 'parentCID=ffffffff', 'createType="fullDevice"', '', '# Extent description',
                'RW 2500000 FLAT "\\.\PhysicalDrive3" 0', 'RW 1400000 ZERO', '', '# The Disk Data Base', '#DDB', '',
                'ddb.adapterType = "ide"', 'ddb.geometry.cylinders = "16383"', 'ddb.geometry.heads = "16"', 'ddb.geometry.sectors = "63"',
                'ddb.virtualHWVersion = "20"', '') -join "`r`n")
    }

    Context 'on disk' {
        BeforeEach {
            Mock -ModuleName PortableVM Write-Host {}
            $script:descriptor = Join-Path $TestDrive 'descriptor\stick.vmdk'
            $script:log = Join-Path $TestDrive 'descriptor\launcher.log'
            Write-TestFile -Path $script:descriptor -Text (Get-TestDescriptorText)
            Remove-Item -LiteralPath "$script:descriptor.orig", $script:log, (Join-Path $TestDrive 'descriptor\new.vmdk') -ErrorAction SilentlyContinue
            $script:layout = @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive3" 0') }
        }

        It 'are rewritten as UTF-8 without a BOM, with an .orig copy of the first version kept' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout -LogPath $script:log
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly ((Get-TestDescriptorText).Replace('PhysicalDrive1', 'PhysicalDrive3'))
            [IO.File]::ReadAllBytes($script:descriptor)[0] | Should -Be ([byte][char]'#')
            [IO.File]::ReadAllText("$script:descriptor.orig") | Should -BeExactly (Get-TestDescriptorText)
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0')

            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive4" 0') } -LogPath $script:log
            [IO.File]::ReadAllText("$script:descriptor.orig") | Should -BeExactly (Get-TestDescriptorText)
        }

        It 'are left alone when they already point at the stick' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout @{ CreateType = 'fullDevice'; Extents = @('RW 3900000 FLAT "\\.\PhysicalDrive1" 0') } -LogPath $script:log
            "$script:descriptor.orig" | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk already points at the stick')
        }

        It 'are only logged under -WhatIf' {
            Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout -LogPath $script:log -WhatIf
            [IO.File]::ReadAllText($script:descriptor) | Should -BeExactly (Get-TestDescriptorText)
            "$script:descriptor.orig" | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('stick.vmdk -> RW 3900000 FLAT "\\.\PhysicalDrive3" 0')
        }

        It 'stop the launcher when they hold no extent' {
            Write-TestFile -Path $script:descriptor -Text 'createType="fullDevice"'
            $message = try { Set-PvmDiskDescriptor -Path $script:descriptor -Layout $script:layout -LogPath $script:log } catch { Get-PvmStopMessage -ErrorRecord $_ }
            $message | Should -BeExactly "Unexpected content in $script:descriptor - no disk extent found. Nothing was started."
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

Describe 'Drive letters' {
    It 'move every quoted path below the root to the new letter, for both separators' {
        $text = '<a src="Q:\Portable\Stick\VirtualBox\x.vbox"/><b location="Q:/Portable/Stick/VirtualBox/x.vmdk"/><c path="Q:\Other\x"/>'
        ConvertTo-PvmDriveLetterText -Text $text -Root 'D:\Portable\Stick' -Letter 'E' |
            Should -BeExactly '<a src="E:\Portable\Stick\VirtualBox\x.vbox"/><b location="E:/Portable/Stick/VirtualBox/x.vmdk"/><c path="Q:\Other\x"/>'
    }

    It 'change nothing when the root is a drive root (known issue, phase 5)' {
        ConvertTo-PvmDriveLetterText -Text '<a src="Q:\VirtualBox\x.vbox"/>' -Root 'D:\' -Letter 'E' | Should -BeExactly '<a src="Q:\VirtualBox\x.vbox"/>'
    }

    It 'change nothing when the case of the folders differs (known issue, phase 5)' {
        ConvertTo-PvmDriveLetterText -Text '<a src="Q:\portable\stick\x.vbox"/>' -Root 'D:\Portable\Stick' -Letter 'E' | Should -BeExactly '<a src="Q:\portable\stick\x.vbox"/>'
    }

    It 'read a $ in a folder name as a substitution (known issue, phase 5)' {
        ConvertTo-PvmDriveLetterText -Text '<a src="Q:\A$&B\x"/>' -Root 'D:\A$&B' -Letter 'E' | Should -BeExactly '<a src="E:\A"Q:\A$&B\B\x"/>'
    }

    Context 'in a file' {
        BeforeEach {
            Mock -ModuleName PortableVM Write-Host {}
            $script:file = Join-Path $TestDrive 'letters\VirtualBox.xml'
            $script:log = Join-Path $TestDrive 'letters\launcher.log'
            Write-TestFile -Path $script:file -Text '<e src="Q:\Portable\Stick\x.vbox"/>'
            Remove-Item -LiteralPath "$script:file.launcher-backup", $script:log -ErrorAction SilentlyContinue
        }

        It 'are rewritten, with a .launcher-backup copy of the first version kept' {
            Set-PvmDriveLetterInFile -Path $script:file -Root 'D:\Portable\Stick' -Letter 'E' -LogPath $script:log
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="E:\Portable\Stick\x.vbox"/>'
            Set-PvmDriveLetterInFile -Path $script:file -Root 'D:\Portable\Stick' -Letter 'F' -LogPath $script:log
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="F:\Portable\Stick\x.vbox"/>'
            [IO.File]::ReadAllText("$script:file.launcher-backup") | Should -BeExactly '<e src="Q:\Portable\Stick\x.vbox"/>'
            Get-TestLog -Path $script:log | Should -BeExactly @('VirtualBox.xml: paths moved to drive E:', 'VirtualBox.xml: paths moved to drive F:')
        }

        It 'are left alone when the letter already fits, also in another case' {
            Set-PvmDriveLetterInFile -Path $script:file -Root 'D:\Portable\Stick' -Letter 'q' -LogPath $script:log
            "$script:file.launcher-backup" | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('VirtualBox.xml: drive letter OK')
        }

        It 'are only logged under -WhatIf' {
            Set-PvmDriveLetterInFile -Path $script:file -Root 'D:\Portable\Stick' -Letter 'E' -LogPath $script:log -WhatIf
            [IO.File]::ReadAllText($script:file) | Should -BeExactly '<e src="Q:\Portable\Stick\x.vbox"/>'
            "$script:file.launcher-backup" | Should -Not -Exist
            Get-TestLog -Path $script:log | Should -BeExactly @('VirtualBox.xml: paths moved to drive E:')
        }
    }
}

Describe 'Running VMs' {
    # -ForEach data is built before BeforeAll runs, so it spells the UUID out.
    It 'count a VirtualBox process as this VM when <Case>' -ForEach @(
        @{ Case = 'its command line names the UUID'; CommandLine = 'VirtualBoxVM.exe --startvm 5ca1ab1e-0000-4000-8000-000000000001'; Uuid = '5ca1ab1e-0000-4000-8000-000000000001'; Expected = $true }
        @{ Case = 'its command line cannot be read'; CommandLine = $null; Uuid = '5ca1ab1e-0000-4000-8000-000000000001'; Expected = $true }
        @{ Case = 'the UUID setting is empty (known issue, phase 3)'; CommandLine = 'VirtualBoxVM.exe --startvm other'; Uuid = ''; Expected = $true }
        @{ Case = 'it names another VM, which it is not'; CommandLine = 'VirtualBoxVM.exe --startvm 5ca1ab1e-0000-4000-8000-000000000009'; Uuid = '5ca1ab1e-0000-4000-8000-000000000001'; Expected = $false }
    ) {
        Test-PvmVirtualBoxVmProcess -Process ([pscustomobject]@{ CommandLine = $CommandLine }) -VmUuid $Uuid | Should -Be $Expected
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
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Filter -ceq $script:vmwareFilter }
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Filter -ceq $script:virtualBoxVmFilter }
            [IO.File]::ReadAllText($script:stick.VMwareDisk) | Should -BeLike '*RW 2500000 FLAT "\\.\PhysicalDrive3" 0*RW 1400000 ZERO*'
            [IO.File]::ReadAllText($script:stick.VMwareDisk) | Should -BeLike '*createType="fullDevice"*'
            "$($script:stick.VMwareDisk).orig" | Should -Exist
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

        It 'reports a VM that already runs in VMware' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'vmware-vmx.exe'; CommandLine = "vmware-vmx.exe `"$($script:stick.Vmx)`"" })
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 0
            $result.Message | Should -BeExactly 'The VM is already running.'
            $result.Icon | Should -BeExactly 'Information'
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeExactly 'Already running in VMware.'
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
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeExactly "STOPPED: $message"

            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 0
            Get-TestLog -Path $script:stick.Log | Should -Contain "DRY RUN - a real start would stop here: $message"
        }
    }

    Context 'in VirtualBox' {
        BeforeEach {
            $script:stick = Initialize-TestStick -Name 'virtualbox-stick'
            Set-TestPc -Stick $script:stick -Installed 'VirtualBox'
        }
        AfterEach { Remove-Item -LiteralPath $script:stick.Root -Recurse -Force }

        It 'fixes the drive letter, points the descriptor at the stick, starts the VM and logs each step' {
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 0
            $below = $script:stick.Root.Substring(2)
            [IO.File]::ReadAllText($script:stick.Vbox) | Should -BeLike "*location=`"$($script:stick.Letter):$below\VirtualBox\Test VM\stick.vmdk`"*"
            [IO.File]::ReadAllText($script:stick.VirtualBoxXml) | Should -BeLike "*src=`"$($script:stick.Letter):$($below.Replace('\', '/'))/VirtualBox/Test VM/Test VM.vbox`"*"
            "$($script:stick.Vbox).launcher-backup" | Should -Exist
            "$($script:stick.VirtualBoxXml).launcher-backup" | Should -Exist
            [IO.File]::ReadAllText($script:stick.VirtualBoxDisk) | Should -BeExactly ((Get-TestDescriptorText -Newline "`n").Replace('PhysicalDrive1', 'PhysicalDrive3'))
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Filter -ceq $script:vmwareFilter }
            Should -Invoke -CommandName Invoke-PvmGetProcess -ModuleName PortableVM -Times 1 -Exactly -ParameterFilter { $Filter -ceq $script:virtualBoxOpenFilter }
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
            )
        }

        It 'reports a VM that already runs while VirtualBox is open' {
            $script:testProcesses = @([pscustomobject]@{ Name = 'VirtualBox.exe'; CommandLine = $null })
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = 'VMState="running"' } } -ParameterFilter { $ArgumentList[0] -eq 'showvminfo' }
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.Message | Should -BeExactly 'The VM is already running.'
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeExactly 'Already running in VirtualBox.'
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

        It 'stops when the VM list lacks the VM' {
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = '"Other" {5ca1ab1e-0000-4000-8000-000000000009}' } } -ParameterFilter { $ArgumentList[0] -eq 'list' }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message |
                Should -BeExactly "VirtualBox did not find the VM in the stick's VM list:`n`n`"Other`" {5ca1ab1e-0000-4000-8000-000000000009}"
        }

        It 'reports a VM that runs by the time VBoxManage asks, without the window note' {
            Mock -ModuleName PortableVM Invoke-PvmNative { [pscustomobject]@{ ExitCode = 0; Output = 'VMState="paused"' } } -ParameterFilter { $ArgumentList[0] -eq 'showvminfo' }
            (Invoke-PortableVM -LauncherPath $script:stick.Launcher).Message | Should -BeExactly 'The VM is already running.'
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeExactly 'VirtualBox VM state: "paused"'
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
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeExactly "STOPPED: $message"
            Should -Invoke -CommandName Invoke-PvmNative -ModuleName PortableVM -Times 0 -Exactly

            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher -DryRun
            $result.ExitCode | Should -Be 0
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
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeExactly "STOPPED: $($result.Message)"
        }

        It 'stops at once on a missing settings file, naming it' {
            Remove-Item -LiteralPath (Join-Path $script:stick.Launcher 'settings.psd1')
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $result.Message | Should -BeLike 'Unexpected error: *settings.psd1*'
            Should -Invoke -CommandName Invoke-PvmGetPartition -ModuleName PortableVM -Times 0 -Exactly
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
            # VirtualBoxVbox names a folder, which cannot be read as a file.
            $script:stick = Initialize-TestStick -Name 'other-stick' -Change @{ VirtualBoxVbox = 'VirtualBox\Test VM' }
            Add-Content -LiteralPath $script:stick.Vmx -Value 'checkpoint.vmState = "Test VM.vmss"'
            $result = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            $result.ExitCode | Should -Be 1
            $log = Get-TestLog -Path $script:stick.Log
            $log[-2] | Should -BeExactly 'Saved state found: suspended in VMware'
            $log[-1] | Should -BeLike 'STOPPED: The launcher cannot tell whether the VM has a saved state in VirtualBox, because the path is a folder, not a file: VirtualBoxVbox in settings.psd1 names *'
        }

        It 'logs the version from VERSION and the note on Memory Integrity' {
            Write-TestFile -Path (Join-Path $script:stick.Launcher 'VERSION') -Text "v0.2.0`n"
            Mock -ModuleName PortableVM Invoke-PvmGetDeviceGuard { [pscustomobject]@{ SecurityServicesRunning = @(1, 2) } }
            $null = Invoke-PortableVM -LauncherPath $script:stick.Launcher
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Launcher version v0.2.0'
            Get-TestLog -Path $script:stick.Log | Should -Contain 'Note: Memory Integrity is on, so the VM runs on top of Hyper-V (slower than native).'
        }

        It 'starts although VERSION cannot be read' {
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
            $result.ExitCode | Should -Be 0
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
            (Get-TestLog -Path $script:stick.Log)[-1] | Should -BeLike "STOPPED: $notResumed"
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
}
