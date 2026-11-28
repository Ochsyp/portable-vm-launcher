# The CI stage lint of the repository standard, which run-stage runs on Windows under Windows
# PowerShell 5.1 from the top of the repository: PSScriptAnalyzer through tests\run-checks.ps1,
# without Pester. install-tools has put the pinned module on the module path; run-checks.ps1 reads
# the same pin. Exits with the checks' code.
# Continue, so a line the checks write to stderr does not stop this script; the exit code decides.
$ErrorActionPreference = 'Continue'
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\tests\run-checks.ps1') -SkipPester
exit $LASTEXITCODE
