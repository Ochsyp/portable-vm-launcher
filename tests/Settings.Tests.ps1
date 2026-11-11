# Tests of the settings code in src\PortableVM.psm1: how LauncherData\settings.psd1 is decoded
# and parsed without running anything, how schema 2 checks every key, the defaults, how deploy
# turns schema 1 text into schema 2, the message templates with the VM's and the guest's names,
# and the data folder's paths. Files live in TestDrive; -ForEach tables are literals, since
# Pester builds them before BeforeAll runs, and text outside ASCII is built at run time, so this
# file stays ASCII.

BeforeAll {
    $script:previousTestFlag = $env:PVM_TEST
    $env:PVM_TEST = '1'
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force
    $script:example = Join-Path $script:repoRoot 'examples\settings.example.psd1'
    # A made-up name with letters outside ASCII that Windows-1252 holds too, so it also tests ANSI.
    $script:sampleName = 'K' + [char]0x00E9 + 'l' + [char]0x00F8 + 'n' + [char]0x00EF

    # Write the bytes $Bytes to TestDrive\$Name and return the path.
    function Write-TestByte {
        param([string]$Name, [byte[]]$Bytes)
        $path = Join-Path $TestDrive $Name
        [IO.File]::WriteAllBytes($path, $Bytes)
        $path
    }

    # Return good schema 2 settings for the synthetic stick, with the values in $Change replaced;
    # a $null in $Change leaves that key out.
    function Get-GoodSetting {
        param([hashtable]$Change = @{})
        $settings = @{
            SchemaVersion = 2; StickMbrSignature = '5CA1AB1E'; StickSectors = 4000000; VmSectors = 3900000; DataPartitionStart = 2500000
            VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000001'; VirtualBoxHome = 'VirtualBox'
            VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'; VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'
            VMwareVmx = 'VMware\Test VM.vmx'; VMwareDisk = 'VMware\stick.vmdk'
        }
        foreach ($key in $Change.Keys) {
            if ($null -eq $Change[$key]) { $settings.Remove($key) } else { $settings[$key] = $Change[$key] }
        }
        $settings
    }

    # Return the reason that Import-PvmDataFile gives for the file $Path, or $null when it loads.
    function Get-ImportError {
        param([string]$Path, [switch]$Legacy)
        try {
            $null = Import-PvmDataFile -Path $Path -Legacy:$Legacy
            $null
        } catch {
            $_.Exception.Message
        }
    }
}

AfterAll {
    Remove-Module PortableVM -ErrorAction SilentlyContinue
    $env:PVM_TEST = $script:previousTestFlag
}

Describe 'Reading a settings file' {
    It 'loads ASCII without a byte order mark, with CRLF and with LF' {
        foreach ($newline in "`r`n", "`n") {
            $path = Write-TestByte -Name 'ascii.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes("@{$newline    Hypervisor = 'Auto'$newline    StickSectors = 4000000$newline}$newline"))
            $values = Import-PvmDataFile -Path $path
            $values['Hypervisor'] | Should -BeExactly 'Auto'
            $values['StickSectors'] | Should -Be 4000000
        }
    }

    It 'loads UTF-8 and UTF-16 with a byte order mark, characters outside ASCII included' {
        $text = "@{ GuestName = '$script:sampleName' }"
        foreach ($encoding in (New-Object System.Text.UTF8Encoding $true), (New-Object System.Text.UnicodeEncoding $false, $true), (New-Object System.Text.UnicodeEncoding $true, $true)) {
            $path = Write-TestByte -Name 'bom.psd1' -Bytes ([byte[]]($encoding.GetPreamble() + $encoding.GetBytes($text)))
            (Import-PvmDataFile -Path $path)['GuestName'] | Should -BeExactly $script:sampleName
        }
    }

    It 'refuses characters outside ASCII without a byte order mark, and asks for UTF-8 with BOM' {
        $path = Write-TestByte -Name 'utf8-no-bom.psd1' -Bytes ((New-Object System.Text.UTF8Encoding $false).GetBytes("@{ GuestName = '$script:sampleName' }"))
        Get-ImportError -Path $path | Should -BeExactly 'it holds characters outside ASCII but no byte order mark; save it as UTF-8 with BOM'
    }

    It 'reads a file without a byte order mark as ANSI with -Legacy, as the launcher before schema 2 did' {
        $bytes = [Text.Encoding]::Default.GetBytes("@{ GuestName = '$script:sampleName' }")
        $path = Write-TestByte -Name 'ansi.psd1' -Bytes $bytes
        (Import-PvmDataFile -Path $path -Legacy)['GuestName'] | Should -BeExactly ([Text.Encoding]::Default.GetString($bytes) -replace "^@\{ GuestName = '|' \}$", '')
        Get-ImportError -Path $path | Should -BeLike '*save it as UTF-8 with BOM'
    }

    It 'reads a file without a byte order mark as ANSI with -Legacy also when it holds UTF-8, as the launcher before schema 2 did' {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes("@{ GuestName = '$script:sampleName' }")
        ConvertFrom-PvmDataFileByte -Bytes $bytes -Legacy | Should -BeExactly ([Text.Encoding]::Default.GetString($bytes))
    }

    It 'refuses bytes that are no valid UTF-8 after a UTF-8 byte order mark' {
        $path = Write-TestByte -Name 'broken.psd1' -Bytes ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("@{ A = '") + [byte[]](0xC3, 0x28) + [Text.Encoding]::ASCII.GetBytes("' }"))
        Get-ImportError -Path $path | Should -BeExactly 'it is no valid UTF-8'
    }

    It 'loads plain values: text, numbers, $true, $false, $null, arrays and hashtables' {
        $path = Write-TestByte -Name 'values.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes("@{ A = 'x'; B = `"y`"; C = 1; D = -2; E = 7814037168; F = `$true; G = `$false; H = `$null; I = @(1, 2); J = @{ K = 1 } }"))
        $values = Import-PvmDataFile -Path $path
        $values['B'] | Should -BeExactly 'y'
        $values['E'] | Should -BeOfType [long]
        $values['F'] | Should -BeTrue
        $values.ContainsKey('H') | Should -BeTrue
    }

    It 'refuses <Case>, naming the line but nothing from the file' -ForEach @(
        @{ Case = 'a syntax error'; Text = "@{`r`n    Marker = 'Q7'`r`n"; Message = 'line 3 is no valid PowerShell data (MissingEndCurlyBrace)' }
        @{ Case = 'a key given twice, in another case'; Text = "@{`r`n    Marker = 'Q7'`r`n    marker = 'Q8'`r`n}"; Message = 'line 3 is no valid PowerShell data (DuplicateKeyInHashLiteral)' }
        @{ Case = 'two statements'; Text = "@{ Marker = 'Q7' }`r`n@{ B = 2 }"; Message = 'it must hold one hashtable, @{ ... }, and nothing else' }
        @{ Case = 'an array'; Text = "@('Marker', 'Q7')"; Message = 'it must hold one hashtable, @{ ... }, and nothing else' }
        @{ Case = 'a script block'; Text = "{ @{ Marker = 'Q7' } }"; Message = 'it must hold one hashtable, @{ ... }, and nothing else' }
        @{ Case = 'a param block'; Text = "param() @{ Marker = 'Q7' }"; Message = 'it must hold one hashtable, @{ ... }, and nothing else' }
        @{ Case = 'a redirection'; Text = "@{ Marker = 'Q7' } > out.txt"; Message = 'it must hold one hashtable, @{ ... }, and nothing else' }
        @{ Case = 'a subexpression'; Text = "@{`r`n    Marker = `$('Q7')`r`n}"; Message = 'line 2 holds an expression; use plain text, numbers, $true, $false or $null' }
        @{ Case = 'an environment variable'; Text = "@{ Marker = `$env:Q7 }"; Message = 'line 1 holds an expression; use plain text, numbers, $true, $false or $null' }
        @{ Case = 'a variable in a string'; Text = "@{ Marker = `"Q7 `$HOME`" }"; Message = 'line 1 holds an expression; use plain text, numbers, $true, $false or $null' }
        @{ Case = 'a type conversion'; Text = "@{ Marker = [int]'7' }"; Message = 'line 1 holds an expression; use plain text, numbers, $true, $false or $null' }
        @{ Case = 'a value in parentheses'; Text = "@{ Marker = ('Q7') }"; Message = 'line 1 holds an expression; use plain text, numbers, $true, $false or $null' }
        @{ Case = 'an empty file'; Text = ''; Message = 'it must hold one hashtable, @{ ... }, and nothing else' }
    ) {
        $path = Write-TestByte -Name 'refused.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes($Text))
        $message = Get-ImportError -Path $path
        $message | Should -BeExactly $Message
        $message | Should -Not -Match 'Q7|Marker'
    }

    It 'runs nothing in a file that would create a file' {
        $created = Join-Path $TestDrive 'ran.txt'
        $path = Write-TestByte -Name 'command.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes("@{ A = `$(New-Item -ItemType File -Path '$created') }"))
        Get-ImportError -Path $path | Should -BeLike '*holds an expression*'
        $created | Should -Not -Exist
    }
}

Describe 'Checking settings against schema 2' {
    It 'finds nothing wrong with good settings, with or without the optional keys' {
        @(Test-PvmSetting -Settings (Get-GoodSetting)) | Should -BeNullOrEmpty
        $all = @{ IsExample = $false; VmDisplayName = 'Test VM'; GuestName = 'Test OS'; Hypervisor = 'virtualbox'; VMwareView = 'fullscreen'; SavedStatePolicy = 'REFUSE'; HideDataPartition = $true }
        @(Test-PvmSetting -Settings (Get-GoodSetting -Change $all)) | Should -BeNullOrEmpty
    }

    It 'accepts <Key> = <Value>' -ForEach @(
        @{ Key = 'StickMbrSignature'; Value = 'abcdef12' }
        @{ Key = 'StickSectors'; Value = 7814037168 }
        @{ Key = 'VmSectors'; Value = 4000000 }
        @{ Key = 'VirtualBoxVmUuid'; Value = '5CA1AB1E-0000-4000-8000-000000000001' }
        @{ Key = 'VmDisplayName'; Value = 'Forty characters long, which is the most' }
        @{ Key = 'GuestName'; Value = 'x' }
    ) {
        @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ $Key = $Value })) | Should -BeNullOrEmpty
    }

    It 'refuses <Key> = <Case>' -ForEach @(
        @{ Key = 'SchemaVersion'; Case = '1'; Value = 1 }
        @{ Key = 'SchemaVersion'; Case = '3'; Value = 3 }
        @{ Key = 'SchemaVersion'; Case = 'text'; Value = '2' }
        @{ Key = 'SchemaVersion'; Case = 'a double'; Value = 2.0 }
        @{ Key = 'IsExample'; Case = 'text'; Value = 'no' }
        @{ Key = 'Hypervisor'; Case = 'an unknown word'; Value = 'VBox' }
        @{ Key = 'Hypervisor'; Case = 'a trailing blank'; Value = 'Auto ' }
        @{ Key = 'Hypervisor'; Case = 'a trailing line feed'; Value = "Auto`n" }
        @{ Key = 'Hypervisor'; Case = 'a number'; Value = 1 }
        @{ Key = 'VMwareView'; Case = 'an unknown word'; Value = 'Full Screen' }
        @{ Key = 'SavedStatePolicy'; Case = 'an unknown word'; Value = 'Never' }
        @{ Key = 'HideDataPartition'; Case = 'text'; Value = 'false' }
        @{ Key = 'HideDataPartition'; Case = 'a number'; Value = 0 }
        @{ Key = 'StickMbrSignature'; Case = '7 digits'; Value = '5CA1AB1' }
        @{ Key = 'StickMbrSignature'; Case = '9 digits'; Value = '5CA1AB1EF' }
        @{ Key = 'StickMbrSignature'; Case = 'none'; Value = 'none' }
        @{ Key = 'StickMbrSignature'; Case = 'zero'; Value = '00000000' }
        @{ Key = 'StickMbrSignature'; Case = 'a trailing line feed'; Value = "5CA1AB1E`n" }
        @{ Key = 'StickMbrSignature'; Case = 'a number'; Value = 12345678 }
        @{ Key = 'StickSectors'; Case = 'text'; Value = '4000000' }
        @{ Key = 'StickSectors'; Case = 'a double'; Value = 4000000.0 }
        @{ Key = 'StickSectors'; Case = 'zero'; Value = 0 }
        @{ Key = 'DataPartitionStart'; Case = 'a negative number'; Value = -1 }
        @{ Key = 'VirtualBoxVmUuid'; Case = 'braces'; Value = '{5ca1ab1e-0000-4000-8000-000000000001}' }
        @{ Key = 'VirtualBoxVmUuid'; Case = 'no hyphens'; Value = '5ca1ab1e000040008000000000000001' }
        @{ Key = 'VirtualBoxVmUuid'; Case = 'empty'; Value = '' }
        @{ Key = 'VirtualBoxVmUuid'; Case = 'a word'; Value = 'x' }
        @{ Key = 'VirtualBoxVmUuid'; Case = 'a trailing line feed'; Value = "5ca1ab1e-0000-4000-8000-000000000001`n" }
        @{ Key = 'VmDisplayName'; Case = '41 characters'; Value = 'Forty-one characters long, one too many!!' }
        @{ Key = 'VmDisplayName'; Case = 'a tab'; Value = "Test`tVM" }
        @{ Key = 'VmDisplayName'; Case = 'a leading blank'; Value = ' Test VM' }
        @{ Key = 'GuestName'; Case = 'a trailing blank'; Value = 'Test OS ' }
        @{ Key = 'GuestName'; Case = 'empty'; Value = '' }
        @{ Key = 'GuestName'; Case = 'a line feed'; Value = "Test`nOS" }
    ) {
        $problems = @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ $Key = $Value }))
        $problems.Count | Should -Be 1
        $problems[0] | Should -BeLike "${Key}: must *"
    }

    It 'accepts a name with letters outside ASCII, an emoji, a joiner inside it, a no-break space or a letter newer than the .NET tables' {
        $penguin = [char]::ConvertFromUtf32(0x1F427)
        $heart = [string][char]0x2764 + [char]0xFE0F
        $names = $script:sampleName, "Debian $penguin", "Test $heart", ('a' + [char]0x200D + 'b'), ('Test' + [char]0x00A0 + 'OS'), ('Node ' + [char]0x20BF), ([string][char]0x1C90 + 'a'), ('x' * 39 + $penguin)
        foreach ($name in $names) {
            @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ GuestName = $name })) | Should -BeNullOrEmpty
        }
    }

    It 'refuses a name that shows nothing or holds a control, format or private-use character, or a joiner or blank at either end' {
        $names = @(
            ('Test' + [char]0xD83D), ('Test' + [char]0x202E + 'OS'), ('Test' + [char]::ConvertFromUtf32(0xE0001)), ('Te' + [char]0x00AD + 'st')
            ('Test' + [char]::ConvertFromUtf32(0x1D173)), ('Te' + [char]::ConvertFromUtf32(0xF0000) + 'st'), ('Te' + [char]0xE000 + 'st')
            ('Debian ' + [char]0x200D), ([string][char]0x200D + ' ' + [char]0x200D), ([string][char]0x200C + 'Test')
            [string][char]0x3164, ([string][char]0x2800 + [char]0x2800), [string][char]0x034F, ([string][char]0x0301 + [char]0x0301), ('x' * 40 + [char]::ConvertFromUtf32(0x1F427))
            [string][char]0xFFFF, [string][char]0xFDD0, [char]::ConvertFromUtf32(0x1FFFF)
        )
        foreach ($name in $names) {
            Test-PvmSetting -Settings (Get-GoodSetting -Change @{ GuestName = $name }) |
                Should -BeExactly @('GuestName: must be 1 to 40 characters of text that shows, without control or formatting characters, and without a blank or a joiner at either end')
        }
    }

    It 'wants VmSectors above DataPartitionStart and at most StickSectors: <Case>' -ForEach @(
        @{ Case = 'VmSectors at the end of the stick'; Change = @{ VmSectors = 4000000 }; Problem = $false }
        @{ Case = 'VmSectors past the end of the stick'; Change = @{ VmSectors = 4000001 }; Problem = $true }
        @{ Case = 'the Data partition starting at VmSectors'; Change = @{ DataPartitionStart = 3900000 }; Problem = $true }
        @{ Case = 'a bad value, which is named on its own instead'; Change = @{ VmSectors = 0 }; Problem = $false }
    ) {
        $problems = @(Test-PvmSetting -Settings (Get-GoodSetting -Change $Change))
        ($problems -contains 'VmSectors: must be above DataPartitionStart and at most StickSectors') | Should -Be $Problem
    }

    It 'refuses a path setting <Value>' -ForEach @(
        @{ Value = '' }, @{ Value = '.' }, @{ Value = '..' }, @{ Value = 'VMware\..\Test VM.vmx' }, @{ Value = 'VMware\.\Test VM.vmx' }
        @{ Value = 'VMware.\Test VM.vmx' }, @{ Value = 'VMware \Test VM.vmx' }, @{ Value = 'VMware\\Test VM.vmx' }, @{ Value = 'VMware\CON.vmx' }
        @{ Value = 'NUL.vmx' }, @{ Value = 'com1.vmx' }, @{ Value = 'C:\VMware\Test VM.vmx' }, @{ Value = 'C:Test VM.vmx' }
        @{ Value = '\\server\share\Test VM.vmx' }, @{ Value = '\VMware\Test VM.vmx' }, @{ Value = '/VMware/Test VM.vmx' }
        @{ Value = 'VMware\Test:VM.vmx' }, @{ Value = 'VMware\Test*.vmx' }, @{ Value = ' VMware\Test VM.vmx' }, @{ Value = 'VMware\Test VM.vmx ' }
        @{ Value = 'VMware\Test VM.vbox' }, @{ Value = 'VMware\' }
    ) {
        $problems = @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ VMwareVmx = $Value }))
        $problems | Should -BeExactly @("VMwareVmx: must name a .vmx file below the folder that holds Launcher and LauncherData, without a drive, '.' or '..'")
    }

    It 'accepts a path setting <Value>, which Windows reads as written' -ForEach @(
        @{ Value = 'VMware\Test VM.vmx' }, @{ Value = 'VMware/Test VM.VMX' }, @{ Value = 'Test VM.vmx' }
        @{ Value = 'a b\c d\Test VM.vmx' }, @{ Value = 'VMware\CONFIG.vmx' }, @{ Value = 'VMware\.hidden\Test VM.vmx' }
    ) {
        @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ VMwareVmx = $Value })) | Should -BeNullOrEmpty
        $joined = Join-Path $TestDrive $Value
        $joined | Should -BeExactly ([IO.Path]::GetFullPath($joined))
    }

    It 'wants a folder, not a file name, in VirtualBoxHome, and no empty one' {
        @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ VirtualBoxHome = 'Data\VirtualBox' })) | Should -BeNullOrEmpty
        foreach ($value in '', '.', 'VirtualBox\') {
            @(Test-PvmSetting -Settings (Get-GoodSetting -Change @{ VirtualBoxHome = $value })) |
                Should -BeExactly @("VirtualBoxHome: must name a folder below the folder that holds Launcher and LauncherData, without a drive, '.' or '..'")
        }
    }

    It 'names every bad key in one list, unknown keys first, then in schema order, and no value' {
        $settings = Get-GoodSetting -Change @{ VMwareDisk = $null; Zeta = 'Q7'; alpha = 'Q8'; Hypervisor = 'Q9'; StickSectors = 'Q10' }
        Test-PvmSetting -Settings $settings | Should -BeExactly @(
            'alpha: unknown setting; compare it with examples\settings.example.psd1'
            'Zeta: unknown setting; compare it with examples\settings.example.psd1'
            "Hypervisor: must be 'Auto', 'VMware' or 'VirtualBox'"
            'StickSectors: must be a whole number above 0'
            'VMwareDisk: missing'
        )
    }

    It 'names each required key that is missing' -ForEach @(
        @{ Key = 'StickMbrSignature' }, @{ Key = 'StickSectors' }, @{ Key = 'VmSectors' }, @{ Key = 'DataPartitionStart' }, @{ Key = 'VirtualBoxVmUuid' }
        @{ Key = 'VirtualBoxHome' }, @{ Key = 'VirtualBoxVbox' }, @{ Key = 'VirtualBoxDisk' }, @{ Key = 'VMwareVmx' }, @{ Key = 'VMwareDisk' }
    ) {
        Test-PvmSetting -Settings (Get-GoodSetting -Change @{ $Key = $null }) | Should -BeExactly @("${Key}: missing")
    }

    It 'matches keys without case' {
        $settings = Get-GoodSetting -Change @{ VMwareVmx = $null }
        $settings['vmwarevmx'] = 'VMware\Test VM.vmx'
        @(Test-PvmSetting -Settings $settings) | Should -BeNullOrEmpty
    }

    It 'says only that the file is still the example while IsExample is $true' {
        Test-PvmSetting -Settings @{ IsExample = $true; Hypervisor = 'VBox' } |
            Should -BeExactly @('IsExample: the file is still the example; fill in your values, then delete the IsExample line')
    }

    It 'says only how to add SchemaVersion to a file without it' {
        Test-PvmSetting -Settings (Get-GoodSetting -Change @{ SchemaVersion = $null; Hypervisor = 'VBox' }) |
            Should -BeExactly @('SchemaVersion: missing; add SchemaVersion = 2 (see examples\settings.example.psd1)')
    }
}

Describe 'Filling in the defaults' {
    It 'gives each missing optional key its default and the sector values as [int64]' {
        $merged = Merge-PvmSetting -Settings (Get-GoodSetting)
        $merged['Hypervisor'] | Should -BeExactly 'Auto'
        $merged['VMwareView'] | Should -BeExactly 'Window'
        $merged['SavedStatePolicy'] | Should -BeExactly 'Ask'
        $merged['HideDataPartition'] | Should -BeFalse
        $merged['IsExample'] | Should -BeFalse
        $merged['VmDisplayName'] | Should -BeExactly 'the VM'
        $merged['GuestName'] | Should -BeExactly 'the guest'
        foreach ($key in 'StickSectors', 'VmSectors', 'DataPartitionStart') { $merged[$key] | Should -BeOfType [long] }
        (Merge-PvmSetting -Settings (Get-GoodSetting -Change @{ Hypervisor = 'VMware' }))['Hypervisor'] | Should -BeExactly 'VMware'
    }

    It 'titles the dialogs with the VM''s name only when it is not the neutral default' {
        Get-PvmCaption -Settings (Merge-PvmSetting -Settings (Get-GoodSetting)) | Should -BeExactly 'Portable VM'
        Get-PvmCaption -Settings (Get-GoodSetting -Change @{ VmDisplayName = 'THE vm' }) | Should -BeExactly 'Portable VM'
        Get-PvmCaption -Settings (Get-GoodSetting -Change @{ VmDisplayName = 'Test VM' }) | Should -BeExactly 'Test VM'
    }
}

Describe 'Importing the settings' {
    It 'stops with every problem in one message' {
        $path = Write-TestByte -Name 'problems.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes("@{ SchemaVersion = 2; Hypervisor = 'VBox' }"))
        $message = try { $null = Import-PvmSetting -Path $path } catch { Get-PvmStopMessage -ErrorRecord $_ }
        $lines = @($message -split "`n")
        $lines[0] | Should -BeExactly 'LauncherData\settings.psd1 has 11 problems:'
        $lines[1] | Should -BeExactly "- Hypervisor: must be 'Auto', 'VMware' or 'VirtualBox'"
        $lines.Count | Should -Be 12
    }

    It 'stops when the file is open in another program, naming the cause but no path' {
        $path = Write-TestByte -Name 'held.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes('@{ SchemaVersion = 2 }'))
        $held = [IO.File]::Open($path, 'Open', 'Read', 'None')
        try { $message = try { $null = Import-PvmSetting -Path $path } catch { Get-PvmStopMessage -ErrorRecord $_ } }
        finally { $held.Dispose() }
        $message | Should -BeExactly 'LauncherData\settings.psd1 cannot be read: it cannot be opened, because it is open in another program.'
    }

    It 'stops when the file is missing or cannot be read' {
        $message = try { $null = Import-PvmSetting -Path (Join-Path $TestDrive 'none.psd1') } catch { Get-PvmStopMessage -ErrorRecord $_ }
        $message | Should -BeExactly 'LauncherData\settings.psd1 is missing. Copy examples\settings.example.psd1 there and fill it in.'
        $path = Write-TestByte -Name 'syntax.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes('@{'))
        $message = try { $null = Import-PvmSetting -Path $path } catch { Get-PvmStopMessage -ErrorRecord $_ }
        $message | Should -BeExactly 'LauncherData\settings.psd1 cannot be read: line 1 is no valid PowerShell data (IncompleteHashLiteral).'
    }

    It 'returns the checked settings with the defaults' {
        $path = Write-TestByte -Name 'good.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes((
                    "@{ SchemaVersion = 2; StickMbrSignature = '5CA1AB1E'; StickSectors = 4000000; VmSectors = 3900000; DataPartitionStart = 2500000; " +
                    "VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000001'; VirtualBoxHome = 'VirtualBox'; VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'; " +
                    "VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'; VMwareVmx = 'VMware\Test VM.vmx'; VMwareDisk = 'VMware\stick.vmdk' }")))
        $settings = Import-PvmSetting -Path $path
        $settings['SavedStatePolicy'] | Should -BeExactly 'Ask'
        $settings['VmSectors'] | Should -BeOfType [long]
    }
}

Describe 'Causes of errors from Windows' {
    # Each message names a path the way a stick names its VM, so a cause that quoted it would show.
    It 'names the cause of <Case> without the path' -ForEach @(
        @{ Case = 'a file open in another program'; HResult = 0x80070020; Cause = 'it is open in another program' }
        @{ Case = 'a locked part of a file'; HResult = 0x80070021; Cause = 'it is open in another program' }
        @{ Case = 'a denied access'; HResult = 0x80070005; Cause = 'access is denied' }
        @{ Case = 'a missing file'; HResult = 0x80070002; Cause = 'it is missing' }
        @{ Case = 'a missing folder'; HResult = 0x80070003; Cause = 'it is missing' }
        @{ Case = 'an existing file'; HResult = 0x80070050; Cause = 'an item of that name exists already' }
        @{ Case = 'an existing folder'; HResult = 0x800700B7; Cause = 'an item of that name exists already' }
        @{ Case = 'a full disk'; HResult = 0x80070070; Cause = 'the disk is full' }
        @{ Case = 'a disk without space'; HResult = 0x80070027; Cause = 'the disk is full' }
        @{ Case = 'a path that is too long'; HResult = 0x800700CE; Cause = 'a path is too long' }
    ) {
        $exception = [IO.IOException]::new("The file 'X:\Ann's VM\stick.vmdk' failed.", [int]$HResult)
        $record = [Management.Automation.ErrorRecord]::new($exception, 'Test', 'NotSpecified', $null)
        Get-PvmErrorCause -ErrorRecord $record | Should -BeExactly $Cause
    }

    It 'names the cause by the type of the error: <Type>' -ForEach @(
        @{ Type = 'UnauthorizedAccessException'; Cause = 'access is denied' }
        @{ Type = 'IO.FileNotFoundException'; Cause = 'it is missing' }
        @{ Type = 'IO.DirectoryNotFoundException'; Cause = 'it is missing' }
        @{ Type = 'Management.Automation.ItemNotFoundException'; Cause = 'it is missing' }
        @{ Type = 'IO.PathTooLongException'; Cause = 'a path is too long' }
        @{ Type = 'InvalidOperationException'; Cause = 'an error of type InvalidOperationException' }
    ) {
        $exception = New-Object -TypeName $Type -ArgumentList "The path 'X:\Ann's VM' failed."
        $record = [Management.Automation.ErrorRecord]::new($exception, 'Test', 'NotSpecified', $null)
        Get-PvmErrorCause -ErrorRecord $record | Should -BeExactly $Cause
    }

    It 'looks through the wrapper that PowerShell puts around an error of a .NET method' {
        $record = try { $null = [IO.File]::ReadAllBytes((Join-Path $TestDrive "Ann's VM [1]\none.psd1")) } catch { $_ }
        $record.Exception | Should -BeOfType ([Management.Automation.MethodInvocationException])
        Get-PvmErrorCause -ErrorRecord $record | Should -BeExactly 'it is missing'
    }
}

Describe 'The example settings' {
    It 'are refused only as the example' {
        Test-PvmSetting -Settings (Import-PvmDataFile -Path $script:example) |
            Should -BeExactly @('IsExample: the file is still the example; fill in your values, then delete the IsExample line')
    }

    It 'fail on the stick''s identity once IsExample is deleted, and keep the title Portable VM' {
        $text = [IO.File]::ReadAllText($script:example) -replace '(?m)^\s*IsExample = \$true\r?\n', ''
        $path = Write-TestByte -Name 'example.psd1' -Bytes ([Text.Encoding]::ASCII.GetBytes($text))
        $values = Import-PvmDataFile -Path $path
        @(Test-PvmSetting -Settings $values | ForEach-Object { ($_ -split ':')[0] }) |
            Should -BeExactly @('StickMbrSignature', 'StickSectors', 'VmSectors', 'DataPartitionStart')
        Get-PvmCaption -Settings $values | Should -BeExactly 'Portable VM'
    }
}

Describe 'Turning schema 1 text into schema 2' {
    BeforeAll {
        # Schema 1 settings as the launcher before LauncherData read them, with comments and CRLF.
        $script:schema1 = (@('# My settings, @{ in a comment', '@{', '    # Which program runs the VM', "    Hypervisor = 'Auto'",
                "    StickMbrSignature = '5CA1AB1E'", '    StickSectors = 4000000', '    VmSectors = 3900000', '    DataPartitionStart = 2500000',
                "    VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000001'", "    VirtualBoxHome = 'VirtualBox'",
                "    VirtualBoxVbox = 'VirtualBox\Test VM\Test VM.vbox'", "    VirtualBoxDisk = 'VirtualBox\Test VM\stick.vmdk'",
                "    VMwareVmx = 'VMware\Test VM.vmx'", "    VMwareDisk = 'VMware\stick.vmdk'", '}', '') -join "`r`n")
    }

    It 'adds SchemaVersion right after the @{ that opens the hashtable and keeps every other character' {
        $new = ConvertTo-PvmSchema2Text -Text $script:schema1
        $new | Should -BeExactly ($script:schema1.Replace("@{`r`n    # Which", "@{`r`n    SchemaVersion = 2`r`n    # Which"))
        $values = (Get-PvmDataFileHashtable -Text $new).SafeGetValue()
        @(Test-PvmSetting -Settings $values) | Should -BeNullOrEmpty
        $values['SchemaVersion'] | Should -Be 2
        $values.Count | Should -Be 12
    }

    It 'keeps LF line endings and adds the names, with quotes doubled, only when they are given' {
        $lf = $script:schema1.Replace("`r`n", "`n")
        $name = "Ann's VM" + [char]0x2019 + 's'
        $new = ConvertTo-PvmSchema2Text -Text $lf -VmDisplayName $name -GuestName 'Test OS'
        $new | Should -Not -Match "`r"
        $values = (Get-PvmDataFileHashtable -Text $new).SafeGetValue()
        $values['VmDisplayName'] | Should -BeExactly $name
        $values['GuestName'] | Should -BeExactly 'Test OS'
        (ConvertTo-PvmSchema2Text -Text $lf -GuestName 'Test OS') | Should -Not -Match 'VmDisplayName'
    }

    It 'puts the new keys on lines of their own in a one-line hashtable and after a comment on the @{ line' {
        foreach ($text in "@{ Hypervisor = 'Auto' }", "@{ # note`n    Hypervisor = 'Auto'`n}") {
            $values = (Get-PvmDataFileHashtable -Text (ConvertTo-PvmSchema2Text -Text $text)).SafeGetValue()
            $values['SchemaVersion'] | Should -Be 2
            $values['Hypervisor'] | Should -BeExactly 'Auto'
        }
        ConvertTo-PvmSchema2Text -Text "@{ # note`n    Hypervisor = 'Auto'`n}" | Should -BeExactly "@{ # note`n    SchemaVersion = 2`n    Hypervisor = 'Auto'`n}"
    }

    It 'refuses text that has SchemaVersion already, or a value that is an expression' {
        { ConvertTo-PvmSchema2Text -Text '@{ SchemaVersion = 2 }' } | Should -Throw -ExpectedMessage 'it has SchemaVersion already'
        { ConvertTo-PvmSchema2Text -Text '@{ A = $env:X }' } | Should -Throw -ExpectedMessage '*holds an expression*'
    }
}

Describe 'Messages with names' {
    It 'fill in the VM''s and the guest''s names and other values, capitalised where a sentence starts' {
        Format-PvmMessage -Template '{VM} and {vm}; {Guest} and {guest}; {Path}; {Unknown}' -Names @{ VM = 'my VM'; Guest = 'my guest' } -Values @{ Path = 'X' } |
            Should -BeExactly 'My VM and my VM; My guest and my guest; X; {Unknown}'
    }

    It 'insert a name or a value as plain text, never reading it as a token' {
        Format-PvmMessage -Template '{VM} reads {Path}.' -Names @{ VM = 'A $& {guest} $1'; Guest = 'B' } -Values @{ Path = 'C:\{vm}\$0' } |
            Should -BeExactly 'A $& {guest} $1 reads C:\{vm}\$0.'
    }

    It 'read the same as before the names with the neutral defaults' {
        Format-PvmMessage -Template "{VM} is suspended. Resume it only if {guest}'s disk is safe.`n`nResume {vm} now?" -Names @{ VM = 'the VM'; Guest = 'the guest' } |
            Should -BeExactly "The VM is suspended. Resume it only if the guest's disk is safe.`n`nResume the VM now?"
    }
}

Describe 'The data folder' {
    It 'lies beside the Launcher folder' {
        $paths = Get-PvmDataPath -LauncherPath (Join-Path $TestDrive 'stick\Launcher')
        $paths.Root | Should -BeExactly (Join-Path $TestDrive 'stick')
        $paths.Settings | Should -BeExactly (Join-Path $TestDrive 'stick\LauncherData\settings.psd1')
        $paths.Log | Should -BeExactly (Join-Path $TestDrive 'stick\LauncherData\logs\launcher.log')
        $paths.Backups | Should -BeExactly (Join-Path $TestDrive 'stick\LauncherData\backups')
        $paths.Legacy | Should -BeExactly (Join-Path $TestDrive 'stick\LauncherData\backups\legacy')
        $paths.OldSettings | Should -BeExactly (Join-Path $TestDrive 'stick\Launcher\settings.psd1')
    }

    It 'keeps a file''s first version at its path below the stick folder' {
        $root = Join-Path $TestDrive 'stick'
        $backups = Join-Path $root 'LauncherData\backups'
        Get-PvmBackupPath -Root $root -Backups $backups -Path (Join-Path $root 'VMware\stick.vmdk') -Suffix '.orig' |
            Should -BeExactly (Join-Path $backups 'VMware\stick.vmdk.orig')
        Get-PvmBackupPath -Root "$root\" -Backups $backups -Path (Join-Path $root 'VirtualBox\VirtualBox.xml') -Suffix '.launcher-backup' |
            Should -BeExactly (Join-Path $backups 'VirtualBox\VirtualBox.xml.launcher-backup')
        { Get-PvmBackupPath -Root $root -Backups $backups -Path (Join-Path $TestDrive 'other\x.vmdk') -Suffix '.orig' } | Should -Throw
    }
}
