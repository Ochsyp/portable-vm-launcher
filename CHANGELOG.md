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
  keeps the old launcher as `Launcher.previous`, leaves `LauncherData` as it is, and moves an older
  launcher `.cmd` into `Launcher.previous`.
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
- One launcher run at a time (phase 4): a start or a dry run holds the named mutex
  `Global\PortableVM-Launcher` from before its first log line until it returns, the resume
  question included. Another run meanwhile stops with "Another run of the launcher is in progress
  on this PC ..." before it reads the stick, and a second double-click says so before it asks for
  administrator rights. A lock left by a run that ended without releasing it is taken over and
  noted in the log.
- Log rotation: when `LauncherData\logs\launcher.log` holds 1 MiB or more, or starts with a line
  in the format before phase 4, the run that holds the lock renames it to
  `launcher-<yyyyMMdd-HHmmss>.log` before its first line and starts a new one. The launcher
  deletes no log.
- More of each run in the log: the request for administrator rights, and a declined or failed
  request with its error; a `Timings:` line with each step's duration and
  `----- End: exit code N -----` at the end of every run that the module begins; `Error detail:`,
  `Error ID:` and `Error trace:` lines after an unexpected error, and the system's message when
  the settings file cannot be opened; and a line when a start waits for VirtualBox's background
  service.
- `tests\StartScript.Tests.ps1` for the script's own functions; a dry-run parity table that runs
  each case as a real start and as a dry run and compares their decisions; Repo checks that the
  module branches on `-DryRun` only where it must, keeps the mutex and the rights check in their
  helpers, deletes nothing and moves only the log, that the module and the script append each log
  text in one write, and that the script checks the lock before its administrator-rights block
  and ends unhandled errors in a trap that logs and shows them.
- Safe writes (phase 5): every file the launcher or the deploy tool writes on the stick goes
  to `<file>.pvm-tmp` beside it first, is forced onto the stick and read back, and only then
  takes the file's place, the replaced version staying as `<file>.pvm-old` until the new one
  reads back. A crash or a pulled stick leaves the old or the new version, never a mix, and the
  next start, in either hypervisor, stops at a leftover copy and names the one step to take,
  which keeps the version from before that write, or the copy itself beside a copy whose old
  version repeats its file as it is now; when that file is missing or cannot be read, it asks
  for the file first rather than guess. A new version that does not read back from its place,
  and an old one that cannot be removed after three tries a second apart, stop the start the
  same way, before the VM starts.
- A copy of the version before the latest rewrite, `*.previous.orig` or
  `*.previous.launcher-backup` in `LauncherData\backups`, beside the first version, which stays
  as it was. A rewrite that fails puts back the copy it replaced.
- Tests of the safe write, the descriptor parser, the drive-letter rule, both copies and a start
  that checks every file before it changes one. Repo checks that the module writes files only
  through the safe write, apart from its log, and deletes, moves or swaps a file only in that
  write or to put the log aside, and that the deploy tool writes files only through it.
- The code also runs under PowerShell 7, the engine Linux uses; `Start VM.cmd` still runs it in
  Windows PowerShell 5.1. On Windows the log is opened only to append in both engines, so a
  write stays in one piece, and it stays in the system's ANSI code page. The lock check before
  the prompt for administrator rights and the deploy tool's check of a file it moves work in
  both engines too. When the clone's module does not load, the deploy tool reads it as the
  running engine reads a script, ANSI or UTF-8, to say whether it does not parse.
- CI runs the tests in PowerShell 7 on Windows and on Linux, beside the Windows PowerShell 5.1
  job. `tests\run-checks.ps1` takes `-Tag` and `-ExcludeTag`; `WindowsOnly` marks a test that
  needs Windows, and the Linux job leaves those out. In PowerShell 7 on Windows it uses the
  pinned modules installed for Windows PowerShell.
- Rules that hold on Windows and on Linux alike, with nothing changed for a start on Windows:
  path settings refuse the characters Windows forbids on every system; path settings and backup
  copies use the system's separator, and outside Windows names compare in their case, which the
  message about a missing VM file then says; error causes read Linux's error numbers; the
  descriptor parser takes a device below `/dev` as a raw disk, and a disarmed copy names
  `/dev/PortableVM-disarmed` for it; the launcher finds the stick through a location (the drive
  letter on Windows) and stops, on a system without one yet, before it reads a disk; running
  VMs are found by program name. The pre-push hook runs its privacy check in `pwsh` where
  `powershell.exe` is missing. 497 tests now run in the Linux job, up from 287.

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
  another program or a drive that reports a read error, and leaves out the system's message, which
  can name folders on the stick or above the clone; `-Verbose` shows that message. The launcher
  reports a settings file that it cannot open by its cause too.
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
- Log lines read `<local time with milliseconds and UTC offset> [<process ID>]  <message>`, as in
  `2026-11-12T08:15:06.904+01:00 [6732]  ----- Start VM -----`, every line of a message that spans
  lines included. The message still follows the first two consecutive spaces. Each message is
  appended in one write that other launcher processes cannot break up or block; before, a second
  writer failed.
- A log that cannot be written when a run starts stops the launcher before it reads the PC,
  naming the cause. A later failure to write changes no decision and no longer hides a message:
  the message says that the log is incomplete, and a start that succeeded says that the VM was
  started, with that note, as a warning. Before, a log error hid the message box.
- An unexpected error names the step it happened in, as in "Unexpected error while finding the
  stick: ...", with the innermost error's message.
- The launcher takes the stick's drive letter from the root of its path. It stops with a message
  when it runs from a path without a drive letter, or from a letter that no partition has, such as
  a network or substituted drive. Before, it took the path's first character.
- Dry runs take a real start's decisions: they need administrator rights, take the lock, wait for
  VirtualBox's background service, and exit with 1 and the first message a real start would stop
  with (before: 0 and no message). They still change no VM file, start nothing, ask nothing, and
  do not ask VBoxManage for the VM list or the VM's state after the file step.
- A raw-disk descriptor is read byte for byte and only its extent lines and `createType` change;
  every other byte stays, a windows-1252 one and a byte order mark too, where it was read as
  UTF-8 and written back without them. A descriptor without `createType` gets one. A descriptor
  the launcher does not understand stops the start, naming the line: an extent other than FLAT
  on a raw disk or ZERO, extents apart from each other, `createType` set twice, a line of no
  known kind, a disk image or binary content. Before, such a file could be half rewritten.
- A raw-disk descriptor that already points at the stick is left alone when it differs only by
  blanks or tabs at the end of an extent or `createType` line. VMware ends an extent line with a
  blank when it writes the file, so before, every VMware start rewrote the descriptor and
  replaced its `.previous` copy for nothing. Any other difference is still written.
- The drive-letter fix ignores the case of folder names, takes a `$` in a folder name literally,
  matches an `&` as VirtualBox writes it (`&amp;`), and works when the stick folder is a drive
  root: there it moves only the paths on the stick's old letter, which the paths to the VM's own
  files show, so a path on another drive never moves. A VirtualBox file that is not UTF-8 stops
  the start instead of being rewritten with replacement characters, and a byte order mark stays.
- A start checks every VM file it would change before it changes the first one, so a refusal
  leaves all of them as they were. A read-only or linked VM file, or such a copy of the version
  before its latest rewrite, stops the start, a dry run too, with a message that names it.
- The deploy tool writes the code, `VERSION`, `SHA256SUMS`, the migrated settings and the
  disarmed copies through the safe write. It stops at a leftover copy instead of overwriting
  it: before it changes anything at one beside the staged `Start VM.cmd.new`, and at one beside
  a copy it disarms, whose step `-Verbose` names.
- A deploy keeps one earlier launcher and needs no folder moved by hand. Once the new launcher is
  in place and checked, it deletes the copy before it, and only when every file in that copy is
  what a deploy wrote; anything else stops the deploy before its first change. It never touches
  `LauncherData`, the VM files or any other folder. A deploy that is cut off leaves the older copy
  as `Launcher.previous.remove`, and the next one finishes the removal or names the renames to do.

[Unreleased]: https://github.com/Ochsyp/portable-vm-launcher/commits/main
