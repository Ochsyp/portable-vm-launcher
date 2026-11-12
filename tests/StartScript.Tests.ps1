# Tests of the functions of src\Start-PortableVM.ps1, the entry script: its log lines before and
# around the module, the lock check before it asks for administrator rights, and its dialogs. The
# tests parse the script and load its functions only, so its top-level statements, its trap and the
# administrator-rights block never run here. Dialogs are mocked, the lock check uses unique Local\
# names, and $env:PVM_TEST makes an unmocked adapter of the module throw.

BeforeAll {
    $script:previousTestFlag = $env:PVM_TEST
    $env:PVM_TEST = '1'
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'src\Start-PortableVM.ps1'), [ref]$null, [ref]$parseErrors)
    if (@($parseErrors).Count) { throw "src\Start-PortableVM.ps1 does not parse: $($parseErrors[0].Message)" }
    foreach ($function in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    # Point the script's functions at a fresh synthetic stick in TestDrive, with LauncherData, as
    # the script's own variables do: $Here is the Launcher folder.
    function Initialize-TestStick {
        $script:stickRoot = Join-Path $TestDrive 'stick'
        Remove-Item -LiteralPath $script:stickRoot -Recurse -Force -ErrorAction SilentlyContinue
        $script:Here = Join-Path $script:stickRoot 'Launcher'
        $null = New-Item -ItemType Directory -Path $script:Here, (Join-Path $script:stickRoot 'LauncherData') -Force
        $script:log = Join-Path $script:stickRoot 'LauncherData\logs\launcher.log'
        $script:DryRun = $false
        $script:AskingForRights = $false
    }

    # Return the messages of the log, without their prefixes.
    function Get-TestLog {
        @([IO.File]::ReadAllLines($script:log, [Text.Encoding]::Default) | ForEach-Object { $_ -replace '^.*?  ', '' })
    }
}

AfterAll {
    Remove-Module PortableVM -ErrorAction SilentlyContinue
    $env:PVM_TEST = $script:previousTestFlag
}

Describe 'The script''s log lines' {
    BeforeEach {
        Mock Write-Host {}
        Initialize-TestStick
    }

    It 'are made as the module makes them' {
        foreach ($offset in 1, -5) {
            $time = [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours($offset))
            foreach ($message in 'one', "one`ntwo", '') {
                Format-LogText -Time $time -ProcessId 4242 -Message $message | Should -BeExactly (Format-PvmLogText -Time $time -ProcessId 4242 -Message $message)
            }
        }
    }

    It 'are made as the module makes them under a culture with another time separator too' {
        $culture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::new('fi-FI')
            $time = [DateTimeOffset]::new(2026, 11, 12, 10, 15, 30, 123, [TimeSpan]::FromHours(1))
            $time.ToString('HH:mm:ss') | Should -BeExactly '10.15.30'
            Format-LogText -Time $time -ProcessId 4242 -Message 'x' | Should -BeExactly '2026-11-12T10:15:30.123+01:00 [4242]  x'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }
    }

    It 'are shown on the console but not written without LauncherData, and nothing is created' {
        Remove-Item -LiteralPath (Join-Path $script:stickRoot 'LauncherData') -Recurse
        Add-LogLine -Message 'x' | Should -BeExactly ''
        Join-Path $script:stickRoot 'LauncherData' | Should -Not -Exist
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like '*  x' }
    }

    It 'are written in ANSI, as the module writes them' {
        Add-LogLine -Message "caf$([char]0xE9)" | Should -BeExactly ''
        $bytes = [IO.File]::ReadAllBytes($script:log)
        $expected = [Text.Encoding]::Default.GetBytes("caf$([char]0xE9)`r`n")
        [Convert]::ToBase64String($bytes, $bytes.Length - $expected.Length, $expected.Length) | Should -BeExactly ([Convert]::ToBase64String($expected))
    }

    It 'name the cause of a failed write as the module does: <Case>' -ForEach @(
        @{ Case = 'open in another program'; HResult = 0x80070020 }
        @{ Case = 'locked'; HResult = 0x80070021 }
        @{ Case = 'denied'; HResult = 0x80070005 }
        @{ Case = 'missing file'; HResult = 0x80070002 }
        @{ Case = 'missing folder'; HResult = 0x80070003 }
        @{ Case = 'existing file'; HResult = 0x80070050 }
        @{ Case = 'existing item'; HResult = 0x800700B7 }
        @{ Case = 'full disk'; HResult = 0x80070070 }
        @{ Case = 'disk without space'; HResult = 0x80070027 }
        @{ Case = 'path too long'; HResult = 0x800700CE }
        @{ Case = 'write-protected'; HResult = 0x80070013 }
        @{ Case = 'not ready'; HResult = 0x80070015 }
        @{ Case = 'not connected'; HResult = 0x8007048F }
        @{ Case = 'CRC error'; HResult = 0x80070017 }
        @{ Case = 'device error'; HResult = 0x8007045D }
        @{ Case = 'no access for the system'; HResult = 0x80070780 }
        @{ Case = 'not from Windows'; HResult = 0x80131620 }
    ) {
        $exception = [IO.IOException]::new("The file 'X:\Ann's VM\launcher.log' failed.", [int]$HResult)
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'Test', 'NotSpecified', $null)
        Get-ErrorCause -Exception $exception | Should -BeExactly (Get-PvmErrorCause -ErrorRecord $record)
    }

    It 'are appended with the prefix and this process''s ID, one per line of the message, creating the logs folder' {
        Add-LogLine -Message "a`nb" | Should -BeExactly ''
        $lines = [IO.File]::ReadAllLines($script:log)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match ('\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[' + $PID + '\]  a\z')
        $lines[1] | Should -Match ('\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d \[' + $PID + '\]  b\z')
    }

    It 'return the cause, without a path, of why they could not be written, without throwing' {
        $null = Add-LogLine -Message 'first'
        $holder = [IO.File]::Open($script:log, 'Open', 'Read', 'Read')
        try { $reason = Add-LogLine -Message 'second' }
        finally { $holder.Dispose() }
        $reason | Should -BeExactly 'it is open in another program'
        @(Get-TestLog) | Should -BeExactly @('first')
    }

    It 'describe an error as the module does' {
        $missing = try { $null = [IO.File]::ReadAllText((Join-Path $TestDrive 'none\x.txt')) } catch { $_ }
        $thrown = try { throw 'boom' } catch { $_ }
        foreach ($record in $missing, $thrown) {
            @(Get-ErrorDetail -ErrorRecord $record) | Should -BeExactly @(Format-PvmErrorDetail -ErrorRecord $record)
        }
    }
}

Describe 'The warning of the rights request' {
    BeforeEach {
        Mock Write-Host {}
        Mock Show-Dialog {}
        Initialize-TestStick
        $script:AskingForRights = $true
        $script:warning = 'The launcher needs administrator rights, because the VM boots this USB stick directly.'
    }

    It 'is logged with the error of the step that asked, then shown as the step gives it' {
        # The administrator-rights block calls Show-Message from its catch block in this way.
        try { throw [InvalidOperationException]::new('This command cannot be run due to the error: The operation was canceled by the user.') }
        catch { Show-Message $script:warning 'Warning' }
        $lines = Get-TestLog
        $lines[0] | Should -BeExactly "STOPPED: $script:warning"
        $lines[1] | Should -BeExactly 'Error detail: System.InvalidOperationException: This command cannot be run due to the error: The operation was canceled by the user.'
        @($lines | Where-Object { $_ -like 'Error ID: *' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -like 'Error trace: *' }).Count | Should -BeGreaterOrEqual 1
        Should -Invoke Show-Dialog -Times 1 -Exactly -ParameterFilter { $Message -ceq $script:warning -and $Icon -eq 'Warning' }
        $script:AskingForRights | Should -BeFalse
    }

    It 'says in the dialog when it could not be logged' {
        $null = Add-LogLine -Message 'first'
        $holder = [IO.File]::Open($script:log, 'Open', 'Read', 'Read')
        try {
            try { throw [InvalidOperationException]::new('canceled') }
            catch { Show-Message $script:warning 'Warning' }
        } finally {
            $holder.Dispose()
        }
        Should -Invoke Show-Dialog -Times 1 -Exactly -ParameterFilter {
            $Message -ceq "$script:warning`n`nThe launcher could not write this message to its log, LauncherData\logs\launcher.log, because it is open in another program."
        }
    }

    It 'is not logged without the flag, and a dry run shows no dialog' {
        $script:AskingForRights = $false
        Show-Message 'a message' 'Error'
        $script:log | Should -Not -Exist
        Should -Invoke Show-Dialog -Times 1 -Exactly
        $script:DryRun = $true
        Show-Message 'a message' 'Error'
        Should -Invoke Show-Dialog -Times 1 -Exactly
    }
}

Describe 'The request for administrator rights' {
    BeforeEach {
        Mock Write-Host {}
        Initialize-TestStick
        Mock Test-LockHeld { $false }
        Mock Test-Administrator { $false }
    }

    It 'asks for nothing <Case>' -ForEach @(
        @{ Case = 'in a dry run'; Dry = $true; Admin = $false }
        @{ Case = 'with the rights'; Dry = $false; Admin = $true }
    ) {
        $script:DryRun = $Dry
        $script:admin = $Admin
        Mock Test-Administrator { $script:admin }
        Invoke-RightsRequest | Should -BeNullOrEmpty
        $script:log | Should -Not -Exist
        Should -Invoke Test-LockHeld -Times 0 -Exactly
        $script:AskingForRights | Should -BeFalse
    }

    It 'logs the request and lets the warning be logged, when no run holds the lock' {
        Invoke-RightsRequest | Should -BeNullOrEmpty
        @(Get-TestLog) | Should -BeExactly @('Asking for administrator rights')
        $script:AskingForRights | Should -BeTrue
        Should -Invoke Test-LockHeld -Times 1 -Exactly -ParameterFilter { $Name -ceq (Get-PvmLockName) }
    }

    It 'returns the busy result, logged, without asking, while another run holds the lock' {
        Mock Test-LockHeld { $true }
        $result = Invoke-RightsRequest
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeExactly (Get-PvmBusyMessage)
        $result.Icon | Should -BeExactly 'Error'
        $result.Caption | Should -BeExactly 'Portable VM'
        @(Get-TestLog) | Should -BeExactly @("STOPPED: $(Get-PvmBusyMessage)")
        $script:AskingForRights | Should -BeFalse
    }

    It 'checks the lock without LauncherData too, and logs nothing' {
        Mock Test-LockHeld { $true }
        Remove-Item -LiteralPath (Join-Path $script:stickRoot 'LauncherData') -Recurse
        (Invoke-RightsRequest).Message | Should -BeExactly (Get-PvmBusyMessage)
        Join-Path $script:stickRoot 'LauncherData' | Should -Not -Exist
    }
}

Describe 'The lock check before the prompt' {
    It 'finds no lock on a free name, and finds one while a handle holds the name' {
        # Only a unique Local\ name, never the launcher's own lock.
        $name = "Local\PortableVM-Test-$([guid]::NewGuid())"
        Test-LockHeld -Name $name | Should -BeFalse
        # The check created no mutex of that name.
        $none = $null
        [System.Threading.Mutex]::TryOpenExisting($name, [ref]$none) | Should -BeFalse
        $mutex = [System.Threading.Mutex]::new($false, $name)
        try { Test-LockHeld -Name $name | Should -BeTrue }
        finally { $mutex.Dispose() }
    }

    It 'finds a lock that this process may not open, as when an elevated run holds it' {
        $name = "Local\PortableVM-Test-$([guid]::NewGuid())"
        $security = [System.Security.AccessControl.MutexSecurity]::new()
        $security.AddAccessRule([System.Security.AccessControl.MutexAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().User,
                [System.Security.AccessControl.MutexRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Deny))
        $created = $false
        $mutex = [System.Threading.Mutex]::new($false, $name, [ref]$created, $security)
        try {
            $created | Should -BeTrue
            Test-LockHeld -Name $name | Should -BeTrue
        } finally {
            $mutex.Dispose()
        }
    }
}

Describe 'The result''s message' {
    BeforeEach {
        Mock Write-Host {}
        Initialize-TestStick
    }

    It 'is shown, and the result returned' {
        Mock Show-Message {}
        $result = Show-Result -Result ([pscustomobject]@{ ExitCode = 0; Message = 'm'; Icon = 'Information'; Caption = 'c' })
        $result.ExitCode | Should -Be 0
        Should -Invoke Show-Message -Times 1 -Exactly -ParameterFilter { $Message -ceq 'm' -and $Icon -eq 'Information' -and $Caption -ceq 'c' }
    }

    It 'is logged as an unexpected error with exit code 1 when its dialog fails' {
        Mock Show-Message { throw 'no desktop' }
        $result = Show-Result -Result ([pscustomobject]@{ ExitCode = 0; Message = 'm'; Icon = 'Information'; Caption = 'c' })
        $result.ExitCode | Should -Be 1
        $lines = Get-TestLog
        $lines[0] | Should -BeExactly 'STOPPED: Unexpected error while showing the message: no desktop'
        @($lines | Where-Object { $_ -like 'Error detail: *' }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'The launcher run' {
    BeforeEach {
        Mock Write-Host {}
        Initialize-TestStick
    }

    # The test with the real Import-Module may leave no module behind.
    AfterAll { Import-Module (Join-Path $script:repoRoot 'src\PortableVM.psm1') -Force }

    It 'runs the module and passes the resume question on to the dialog' {
        $script:ask = $null
        Mock Import-Module {}
        Mock Invoke-PortableVM { $script:ask = $AskResume; [pscustomobject]@{ ExitCode = 0; Message = ''; Icon = ''; Caption = 'Portable VM' } }
        Mock Show-Question { $true }
        (Invoke-Launcher).ExitCode | Should -Be 0
        Should -Invoke Invoke-PortableVM -Times 1 -Exactly -ParameterFilter { $LauncherPath -ceq $script:Here -and -not $DryRun }
        & $script:ask 'Q' 'C' | Should -BeTrue
        Should -Invoke Show-Question -Times 1 -Exactly -ParameterFilter { $Message -ceq 'Q' -and $Caption -ceq 'C' }
    }

    It 'names the step when the module cannot be loaded, and logs the details' {
        $result = Invoke-Launcher
        $result.ExitCode | Should -Be 1
        $result.Message | Should -BeLike 'Unexpected error while loading PortableVM.psm1: *'
        $lines = Get-TestLog
        $lines[0] | Should -BeLike 'STOPPED: Unexpected error while loading PortableVM.psm1: *'
        @($lines | Where-Object { $_ -like 'Error detail: *' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'says in the message when it could not be logged' {
        Mock Import-Module { throw 'no module' }
        $null = New-Item -ItemType Directory -Path (Split-Path $script:log) -Force
        [IO.File]::WriteAllText($script:log, '')
        $holder = [IO.File]::Open($script:log, 'Open', 'Read', 'Read')
        try { $result = Invoke-Launcher }
        finally { $holder.Dispose() }
        $result.Message | Should -BeExactly "Unexpected error while loading PortableVM.psm1: no module`n`nThe launcher could not write this message to its log, LauncherData\logs\launcher.log, because it is open in another program."
    }

    It 'names the step when the launcher fails' {
        Mock Import-Module {}
        Mock Invoke-PortableVM { throw 'boom' }
        (Invoke-Launcher).Message | Should -BeExactly 'Unexpected error while running the launcher: boom'
    }

    It 'leaves the tests'' guard of the module''s adapters in place' {
        Mock Import-Module {}
        Mock Invoke-PortableVM { [pscustomobject]@{ ExitCode = 0; Message = ''; Icon = ''; Caption = 'Portable VM' } }
        $null = Invoke-Launcher
        $env:PVM_TEST | Should -BeExactly '1'
    }
}
