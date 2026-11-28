# The CI stage test of the repository standard, which run-stage runs on Windows under Windows
# PowerShell 5.1 from the top of the repository: every Pester test through tests\run-checks.ps1,
# in Windows PowerShell 5.1, the launcher's own engine, then in PowerShell 7 on the same runner.
# A failed or skipped test fails the stage (-FailOnSkip). install-tools has put the pinned Pester
# on the module path, which PowerShell 7 reads too. Exits with the first failing run's code.
# Continue, so a line the checks write to stderr does not stop this script; each exit code decides.
$ErrorActionPreference = 'Continue'
$checks = Join-Path $PSScriptRoot '..\tests\run-checks.ps1'
powershell -NoProfile -ExecutionPolicy Bypass -File $checks -SkipAnalyzer -FailOnSkip
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
pwsh -NoProfile -ExecutionPolicy Bypass -File $checks -SkipAnalyzer -FailOnSkip
exit $LASTEXITCODE
