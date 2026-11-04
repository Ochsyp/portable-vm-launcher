# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). There are no releases yet.

## [Unreleased]

### Added

- The launcher: `Start VM.cmd` and `src\Start-PortableVM.ps1`, as they ran before the
  redesign but with neutral names in the messages, the message box title and the log's start
  line, and `src\PortableVM.psm1`. Phase 1 moved the launcher's checks and start steps into
  that module: functions that take parameters, throw instead of exiting, send every write and
  start through ShouldProcess and reach the PC only through adapters that tests mock. What the
  launcher checks and does is unchanged; `Start VM.cmd` and the script's administrator-rights
  step stay exactly as they were.
- `examples\settings.example.psd1`, whose placeholders match no disk, so the launcher stops at
  its identity check until real values are filled in.
- `tools\Deploy-PortableVM.ps1`, which copies the launcher from a clone to a stick. It checks
  every copy against the clone, writes `VERSION` and `SHA256SUMS`, swaps `Launcher.new` in and
  keeps the old launcher as `Launcher.previous`, carries the stick's settings and log over,
  moves an older launcher `.cmd` into `Launcher.previous`, and deletes nothing.
- `tools\Get-StickInventory.ps1`, a read-only report on the stick, its VM files and the PC that
  prints only check names with yes, no or unknown, for a first look at a real stick.
- `tests\PortableVM.Tests.ps1` and `tests\Tools.Tests.ps1`: characterisation tests of the
  launcher's decisions, messages, log lines and writes, and tests of both tools, on a synthetic
  stick in TestDrive. Known issues that later phases fix are pinned and named.
- `LICENSE` (MIT).
- `.gitattributes`, which stores text with LF and checks PowerShell and batch files out with
  CRLF, and `.gitignore`, which keeps real settings and copies of them, logs, the launcher's
  backups, VM files and disk images out of the repository.
- CI on `windows-latest`: PSScriptAnalyzer 1.25.0 over `src`, `tools`, `tests` and `examples`,
  where any finding fails the run, and Pester 6.2.0 through `tests\run-checks.ps1`, then the
  privacy scan over the tracked files.
- `tests\Repo.Tests.ps1`: no private files tracked, text stored with LF, ASCII sources that
  parse in Windows PowerShell 5.1, a comment above every function, the example settings have
  exactly the keys the launcher reads, and the privacy guard rails refuse what they should. Its
  static guards check that importing the module runs nothing, that in `src` only the script
  exits or shows dialogs, that only the module's adapters read the PC, that no source calls a
  Storage command other than a read or a CIM or WMI method, that the inventory tool calls
  nothing that writes, and that the deploy tool deletes nothing.
- `.githooks/privacy-scan`, which refuses identifiers, private addresses, home paths, e-mail
  addresses and denylisted strings in the contents and names of the files.
- `tools\Find-PrivateData.ps1`, which looks for the values of the real settings file and the
  denylist in git's index and, with `-History`, in every commit, commit message, file name and
  ref name. It prints where, never the value, and exits 0 when clean, 1 on a finding and 2 when
  it cannot run.
- Git hooks: `pre-commit` refuses commits on `main` and runs `privacy-scan` on the staged
  files; `pre-push` refuses pushes to `main` and, when the settings file or the denylist exists,
  runs `tools\Find-PrivateData.ps1 -History`.
- gitleaks with the rules of `privacy-scan`, Dependabot for the pinned GitHub Actions, a pull
  request template, and the README, SECURITY.md, CONTRIBUTING.md and `docs\stick-tests.md`.

### Changed

Compared with the launcher on a stick before the redesign:

- The log names the launcher's version, from `Launcher\VERSION`, after the start line. A
  `VERSION` that cannot be read is logged as unreadable and never stops a start.
- A dry run also prints PowerShell's "What if:" line on the console for each file it would
  change. The log stays the same.
- A settings value of the wrong type, such as an array where one value belongs or an empty
  `VirtualBoxVmUuid`, now stops the launcher with an unexpected error that names the parameter,
  where the launcher before carried on or failed later. Phase 3 checks the settings properly.

[Unreleased]: https://github.com/Ochsyp/portable-vm-launcher/commits/main
