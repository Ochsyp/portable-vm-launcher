## What and why

## Phase

<!-- The phase of the redesign this pull request holds, or "none". -->

## Checks on the test bed or the stick

<!-- What the tests cannot prove and a run on the VHDX test bed, a scratch VM or the stick must, or "none". -->

## Checklist

- [ ] One phase or one change in this pull request
- [ ] `CHANGELOG.md` has an entry under Unreleased
- [ ] `tests\run-checks.ps1` passes (PSScriptAnalyzer and Pester)
- [ ] `sh .githooks/privacy-scan --tracked` passes
- [ ] `tools\Find-PrivateData.ps1 -History` exits 0 after checking at least one value (the settings file or the denylist exists)
- [ ] No disk or VM identifiers, VM or guest names, personal paths, host names, addresses or secrets in the change; examples use the synthetic `5ca1ab1e` identifiers

CONTRIBUTING.md describes the workflow.
