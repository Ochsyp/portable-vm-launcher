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
  launcher checks and does is unchanged; the start line of `Start VM.cmd` and the script's
  administrator-rights step stay exactly as they were, which `tests\Repo.Tests.ps1` checks.
- `examples\settings.example.psd1`, marked `IsExample = $true` and with placeholders that match
  no disk, so the launcher refuses it as the example until the real values are in and the line
  is deleted.
- `tools\Deploy-PortableVM.ps1`, which copies the launcher from a clone to a stick. It checks
  every copy against the clone, writes `VERSION` and `SHA256SUMS`, swaps `Launcher.new` in and
  keeps the old launcher as `Launcher.previous`, leaves `LauncherData` as it is, moves an older
  launcher `.cmd` into `Launcher.previous`, and deletes nothing.
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
- Settings schema 2 (phase 3): `SchemaVersion = 2`, the defaults of the optional keys, and a
  check of every key before the launcher reads the PC. A file with problems stops the launcher
  with one message that names each bad key and no value. The file is parsed as data: only plain
  text, numbers, `$true`, `$false` and `$null` are accepted, so nothing in it runs, not even a
  type conversion. A file without a byte order mark must be ASCII.
- `LauncherData`, beside `Launcher`: `settings.psd1`, `logs\launcher.log` and `backups\`, where
  the launcher keeps the first version of each file it rewrites, at its path below the stick
  folder. Copies of raw-disk descriptors there name a disarmed device instead of a disk.
- `VmDisplayName` and `GuestName`, which name the VM and the guest in messages and the VM in the
  dialog title. Without them the launcher says "the VM" and "the guest" and keeps the title
  'Portable VM', so its messages read as before.
- `tools\Deploy-PortableVM.ps1 -MigrateSettings`, with `-VmDisplayName` and `-GuestName`, which
  moves a stick's schema 1 settings, log and old backup copies to `LauncherData` before the code
  swap, as the README's *Install or update* says. The deploy tool now also installs the launcher
  on a stick without a `Launcher` folder.
- `tests\Settings.Tests.ps1`, the inventory's checks of `LauncherData`, and Repo checks that the
  script's administrator-rights step and the start line of `Start VM.cmd` stay as they were, that
  the module sets strict mode first, and that the deploy tool replaces a file only to disarm a
  descriptor copy.
- A *Public interface* section in the README.

### Changed

Compared with the launcher on a stick before the redesign:

- The log names the launcher's version, from `Launcher\VERSION`, after the start line. A
  `VERSION` that cannot be read is logged as unreadable and never stops a start.
- A dry run also prints PowerShell's "What if:" line on the console for each file it would
  change. The log stays the same.
- The settings and the log moved from `Launcher` to `LauncherData`, and the settings need
  `SchemaVersion = 2`. The launcher stops while `Launcher\settings.psd1` exists, so an old copy
  is not edited by mistake. To upgrade a stick, deploy once with `-MigrateSettings`.
- Settings are checked: a value of the wrong type, such as `'false'` for `$false`, and an
  unknown `Hypervisor`, `VMwareView` or `SavedStatePolicy` stop the launcher. Before, an unknown
  word meant Auto or a window, and a wrong type stopped it with an unexpected error or carried
  on. A path setting must lie below the stick folder, without a drive, `.` or `..`.
- `VirtualBoxVmUuid` is compared as a UUID: a VirtualBox process counts as this VM when a UUID
  in its command line equals it, and VirtualBox's VM list lists the VM only by the UUID at the
  end of a line. Before, the setting was used as a regular expression.
- The launcher keeps its first-version copies in `LauncherData\backups` instead of beside the
  VM files (`.orig`, `.launcher-backup`), and the descriptor copies there are disarmed.
- The deploy tool no longer copies settings or a log into `Launcher`, and refuses settings that
  fail the checks. `tools\Find-PrivateData.ps1` and `pre-push` read `LauncherData\settings.psd1`
  too, and look for the VM's and the guest's names unless they are the neutral defaults. The
  rem line of `Start VM.cmd` names `LauncherData\settings.psd1`.
- The deploy tool reports an error from Windows by its cause, such as a file that is open in
  another program, and leaves out the system's message, which can name folders on the stick;
  `-Verbose` shows that message. The launcher reports a settings file that cannot be opened by
  its cause too.
- A start in VMware needs `suspend.disabled = "TRUE"` and `uuid.action = "keep"` in the `.vmx`;
  without them the launcher stops and names the line to add. With the key set, VMware refuses to
  suspend the VM, and a VM suspended before the key was added still resumes.
- A saved state, which the launcher does not record yet, is resumed only after a Yes in a dialog
  whose default is No: any VirtualBox save, and a VMware suspend from before `suspend.disabled`
  was set. The new setting `SavedStatePolicy = 'Refuse'` makes the launcher stop instead; without
  the setting it asks.
- A `.vmx` or `.vbox` that is missing, cannot be read, lacks `config.version` or is no valid XML
  stops the launcher, naming the setting and the path. Before, a missing file counted as "no saved
  state".

[Unreleased]: https://github.com/Ochsyp/portable-vm-launcher/commits/main
