# portable-vm-launcher

[![CI](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml)

A Windows launcher for a VM that lives on a USB stick and boots that stick as its disk. Plug
the stick into a Windows PC that has VMware Workstation or VirtualBox, double-click
`Start VM.cmd`, and the launcher starts the VM in whichever of the two is installed.

> **Status:** phase 5 of a hardening redesign. The launcher's checks and start steps live in a
> tested module; it guards against suspends and saved states, checks its settings before it
> reads the PC, keeps its settings, log and backups in `LauncherData`, apart from its code, runs
> one start at a time, logs each run with milliseconds, UTC offset, process ID and step timings,
> and rewrites VM files so that a crash never leaves one half-written, as *What it does* and
> *Log* say.
> [CHANGELOG.md](CHANGELOG.md) lists every change. More small pull requests follow. Until they
> land, follow the rules under [Known limits](#known-limits).

## What it does

Before every start the launcher:

- asks for administrator rights, which a VM needs to use a physical disk;
- checks `LauncherData\settings.psd1` before it reads anything on the PC, without running
  anything in it, and names every setting that is wrong in one message;
- finds the stick's disk number on this PC and checks that it is the configured stick: MBR
  disk signature, size, 512-byte sectors and the position of the Data partition it runs from.
  Otherwise nothing starts;
- refuses the PC's own Windows disk;
- points the VM's raw-disk descriptor (`.vmdk`) at that disk number, changing only its extent
  lines and `createType`, and stops at a descriptor it does not understand;
- fixes the stick's drive letter in the VirtualBox files: below a drive root in every quoted
  path below the stick folder, whatever its letter, as before; when the stick folder is a drive
  root, only in the paths on the stick's old letter, so that a path on another drive never moves;
- checks every VM file it would change before it changes the first one, and writes each so that
  a crash or a pulled stick leaves the old or the new version, never a mix;
- refuses to start the VM in one hypervisor while it runs in the other, or while the other
  holds a saved or suspended state;
- refuses to start the VM in VMware unless its `.vmx` has `suspend.disabled = "TRUE"` and
  `uuid.action = "keep"`, and says which line to add;
- asks before it resumes a saved state: any VirtualBox save, or a VMware suspend from before
  `suspend.disabled` was set, which VMware still resumes. No is the default answer, and
  `SavedStatePolicy = 'Refuse'` in the settings makes the launcher stop instead;
- stops when it cannot tell whether the VM is saved, because its `.vmx` or `.vbox` is missing or
  cannot be read, the `.vmx` lacks `config.version` or sets a safety key twice, or the `.vbox` is
  no valid XML;
- runs once at a time on a PC: while a start or a dry run is in progress, another one stops and
  says so, a second double-click before it asks for administrator rights;
- logs every run, from the request for administrator rights to its exit code, with the time each
  step took (see [Log](#log)).

VMware always gets the stick with the Data partition blanked, because Windows keeps using that
partition while the VM runs. For VirtualBox, the `HideDataPartition` setting decides.

Messages and the dialog title name the VM and the guest system as `VmDisplayName` and
`GuestName` in the settings say; without them they say "the VM" and "the guest". Before the
launcher rewrites a VM file, it keeps two copies of it below `LauncherData\backups`: the first
version, which it never replaces, and the version before the latest rewrite, with `.previous`
in its name, which the next rewrite replaces; a rewrite that fails puts back the copy it
replaced. A copy of a raw-disk descriptor names a disarmed device there, so opening it by
mistake reaches no disk.

A rewrite goes to `<file>.pvm-tmp` beside the file first, is forced onto the stick and read
back, and only then takes the file's place; the replaced version stays as `<file>.pvm-old`
until the new one reads back from there, and is then removed, with up to three tries a second
apart. A crash or a pulled stick can leave one of these two beside the file. So can a new
version that does not read back, or an old one that cannot be removed; then the start stops
before the VM starts. The next start, in either hypervisor, stops at such a copy beside a VM
file or beside one of its copies below `LauncherData\backups`, and names the one step to take,
such as removing the `.pvm-tmp` or renaming the `.pvm-old` back. The step keeps the version
from before that write; only beside a copy whose `.pvm-old` repeats its file as it is now does
it keep the copy, and when that file is missing or cannot be read, it asks for the file first
rather than guess.
The next start then makes its change again. Bytes the launcher does not mean
to change stay as they were, a byte order mark too.

`-DryRun` takes the decisions of a real start and logs what would change, without changing a VM
file or starting anything. It still adds its lines to the log and may move a full or old-format
log aside (see [Log](#log)). It needs administrator rights, as a real start has them, and stops
without them, so run it from an elevated PowerShell, with `X:` as the stick's Data partition:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File X:\Launcher\Start-PortableVM.ps1 -DryRun
```

Where a real start would stop, a dry run logs `DRY RUN - a real start would stop here: ...`,
carries on with the other checks, and exits with 1 and the first such message. A stop that
leaves nothing to check after it, such as settings with problems, another disk at the drive
letter, a missing hypervisor or another run in progress, ends a dry run with a `STOPPED:` line as
it ends a real start; after an earlier would-stop line, the dry run still exits with that line's
message. A dry run exits with 1 exactly when its log has such a line. It does not ask
whether to resume a saved state; it logs that a real start would ask. It does not ask VBoxManage
for the VM list or the VM's state after it has checked the files, since that would start
VirtualBox's background service with the stick's files. While that service runs, it waits for it
like a real start, up to 30 seconds.

## Layout on the stick

The stick is MBR-partitioned with 512-byte sectors. The VM sees the sectors from 0 up to the
end of the Data partition, an NTFS partition that Windows mounts and that holds the launcher
and the VM files:

| Path on the Data partition | What it is |
|---|---|
| `Start VM.cmd` | The launcher to double-click |
| `Launcher\` | The launcher's code, which each deploy replaces as a whole; no run writes here |
| `Launcher\Start-PortableVM.ps1` | The script `Start VM.cmd` starts |
| `Launcher\PortableVM.psm1` | The launcher's checks and start steps |
| `Launcher\VERSION`, `Launcher\SHA256SUMS` | The deployed version and the hashes of its code, written by the deploy tool |
| `LauncherData\settings.psd1` | Your settings, copied from `examples\settings.example.psd1` |
| `LauncherData\logs\launcher.log` | The log of every run (see [Log](#log)); full or older logs are kept beside it as `launcher-<date>-<time>.log` |
| `LauncherData\backups\` | The first version of each file the launcher rewrites, and the version before its latest rewrite (`*.previous.*`), at its path below the stick folder; descriptor copies are disarmed |
| `LauncherData\backups\legacy\` | What `-MigrateSettings` moved there: the old settings file and the copies the launcher used to keep beside the VM files |
| `Launcher.previous\` | The one earlier launcher: the one that the last deploy replaced |
| `VMware\` | The VMware VM (`.vmx`) and its raw-disk descriptor |
| `VirtualBox\` | The VirtualBox home: `VirtualBox.xml`, the VM folder and its descriptor |

The table's paths can also lie in a folder below the drive's root; `Launcher` and
`LauncherData` sit side by side in it, and the path settings start from it.

## Log

`LauncherData\logs\launcher.log` is text in the PC's ANSI code page, one line per line of a
message, each after a prefix with the local time to the millisecond, its UTC offset and the ID
of the process that wrote it:

```text
2026-11-12T08:15:02.123+01:00 [4120]  Asking for administrator rights
2026-11-12T08:15:06.904+01:00 [6732]  ----- Start VM -----
2026-11-12T08:15:06.911+01:00 [6732]  Launcher version v0.4.0
2026-11-12T08:15:08.320+01:00 [6732]  Stick found: disk 3 (\\.\PhysicalDrive3), drive X:, ID 5CA1AB1E
2026-11-12T08:15:08.702+01:00 [6732]  Using VMware
2026-11-12T08:15:09.115+01:00 [6732]  stick.vmdk already points at the stick
2026-11-12T08:15:09.180+01:00 [6732]  Started with VMware Workstation (...)
2026-11-12T08:15:09.182+01:00 [6732]  Timings: setup 14 ms, settings 31 ms, stick 1409 ms, choice 382 ms, checks 405 ms, files 21 ms, start 62 ms, total 2324 ms
2026-11-12T08:15:09.183+01:00 [6732]  ----- End: exit code 0 -----
```

- The message starts after the first two consecutive spaces, in the lines of launchers before
  phase 4 too (`yyyy-MM-dd HH:mm:ss` and two spaces). Every line of a message that spans lines
  has the prefix.
- A run starts with `----- Start VM -----`, or `----- Start VM (dry run) -----`, and ends with a
  `Timings:` line, which gives each step's duration in milliseconds, and `----- End: exit code N
  -----`, or `----- End (dry run): exit code N -----`. A run that has its start line but no End
  line was ended before it finished. The End line comes before the run's dialog: a dialog that
  fails adds a `STOPPED:` line after it, and the script then exits with 1; a lock that cannot be
  released adds a `Note:` line after it. Lines in which a dry run differs begin with `DRY RUN - `.
- The script logs a few stops itself, before a run begins: another run in progress at the
  request for administrator rights, a declined or failed request, a `PortableVM.psm1` that
  cannot be loaded, and an error that no step handles. Each is one `STOPPED:` line, with the
  error's details where there was one, and has no start or End line. A declined or failed request
  exits with 0, the others with 1.
- Before Windows asks for administrator rights, the launcher logs `Asking for administrator
  rights`; the elevated run follows under another process ID. A declined or failed request logs a
  `STOPPED:` line with `Error detail:` lines. When the request line is the last line of
  `launcher.log`, the elevated launcher did not run, and an elevated dry run shows why. A log
  that was moved aside can end with the request line of the run that moved it; that run's lines
  start the new `launcher.log`.
- When a start points a disk file at the stick, the line with the new layout is followed by one
  that says why, by kinds only and never a value from the stick, for example
  `stick.vmdk: rewritten because the disk device differs`. The kinds are the disk device, a size,
  a start offset, the access mode, the extent type, the number of extents, a missing or different
  `createType` line, and other line content. A file that differs only in blanks or tabs at the end
  of those lines, or in case, is left alone and logged as `already points at the stick`.
- An unexpected error adds `Error detail:`, `Error ID:` and `Error trace:` lines, which can name
  paths on the stick.
- When `launcher.log` holds 1 MiB or more, or its first line is in the format of a launcher before
  phase 4, the next run moves it to `launcher-<yyyyMMdd-HHmmss>.log` in the same folder and starts
  a new one. The launcher deletes no log.
- To compare runs, drop the prefixes and the `Timings:` lines.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1.
- VMware Workstation or VirtualBox 7 on each PC where the stick is used.
- Administrator rights on that PC.

## Settings

Copy `examples\settings.example.psd1` from this repository to `LauncherData\settings.psd1` on
the stick, fill it in and delete its `IsExample` line; its comments say how to read each value.
Until then the launcher stops and says the file is still the example. The settings follow
schema 2 (`SchemaVersion = 2`): every value is checked before the launcher reads the PC, and a
value of the wrong type or an unknown word is refused rather than guessed. The path settings are
relative to the folder that holds `Launcher` and `LauncherData`, without a drive, `.` or `..`.
Keep the file ASCII, or save it as UTF-8 with BOM; a file without a byte order mark that holds
other characters is refused. The file is read as data, so nothing in it runs.

## Install or update

`tools\Deploy-PortableVM.ps1` copies the launcher from a clone of this repository to a stick,
with `X:` as the stick's Data partition:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Deploy-PortableVM.ps1 -Target X:\
```

It needs a `LauncherData\settings.psd1` that passes the launcher's checks and refuses while a
VM runs on the PC. On a stick without a `Launcher` folder it installs the launcher. Otherwise
it builds the new launcher in `Launcher.new` and checks every copy against the clone before it
changes anything. Then the old `Launcher` becomes `Launcher.previous`, an older launcher `.cmd`
at the stick's root moves in there too, and `Start VM.cmd` takes its place. `LauncherData` and
the VM folders stay as they are. `-WhatIf` runs the checks only and says what it would remove.

A deploy keeps one earlier launcher, so no folder has to be moved by hand between deploys. A
deploy deletes one thing: the earlier launcher copy that the new `Launcher.previous` replaces, and
only when every file in it is what a deploy wrote. It never touches `LauncherData`, the VM files
or any other folder. The older copy waits as `Launcher.previous.remove` until the new launcher is
in place and checked. A `Launcher.previous` that holds anything else, such as the old settings
after a migration, stops the deploy before its first change, and the message says what to move
away. A changed `Launcher` stops it too while a `Launcher.previous` exists, because that
`Launcher` would become the only way back. If a deploy is cut off, the next one finishes the
removal or names the renames to do. A deploy of the commit that `Launcher` already holds, file
for file, stops before any change, so the earlier version stays in `Launcher.previous`.

A stick whose settings are still in `Launcher\settings.psd1`, from a launcher before phase 3,
needs one deploy with `-MigrateSettings`; try it with `-WhatIf` first, which prints the plan:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Deploy-PortableVM.ps1 -Target X:\ -MigrateSettings -WhatIf
```

It writes `LauncherData\settings.psd1` as schema 2 with every value and comment of the old file,
adds `-VmDisplayName` and `-GuestName` when you give them, and keeps a copy of the old file in
`LauncherData\backups\legacy\Launcher`. It moves `Launcher\launcher.log` to
`LauncherData\logs` and the copies the launcher used to keep beside the VM files
(`*.vmdk.orig`, `*.vbox.launcher-backup`, `VirtualBox.xml.launcher-backup`) to
`LauncherData\backups\legacy`, where it disarms the descriptor copies. Any other `*.orig` or
`*.launcher-backup` file stays where it is, and the report counts it. The code swap comes last,
so the old launcher works until then. If the migration stops before the code swap, remove what
its message names, if anything, and run the same command again: it keeps the
`LauncherData\settings.psd1` it wrote and moves what is left, also a log or copy that the old
launcher wrote in between. When the two settings files differ by then, it names the settings that
differ and asks you to make the files agree first. If it stops later, do what its message says;
the new launcher is in place by then. A settings file without a byte order mark whose values read
differently as UTF-8 and as ANSI is refused until it is saved with one.

To go back, rename `Launcher` to any other name, rename `Launcher.previous` to `Launcher`, and
move the old `.cmd` from it back to the stick's root. After a migration, `Launcher.previous`
still holds the old settings file, so the old launcher finds it; `Start VM.cmd` can stay. Going
back reaches one version. For an older one, check out that commit in the clone and deploy it.

## Public interface

What a stick, a script or a user may rely on between versions:

- `Start VM.cmd` at the stick folder starts the launcher; `Launcher\Start-PortableVM.ps1
  -DryRun` takes a real start's decisions without changing a VM file or starting anything,
  writing only its log, and needs administrator rights.
- While a start or a dry run runs, the launcher holds the named mutex
  `Global\PortableVM-Launcher`.
- Log lines start with the prefix that *Log* describes; the message follows the first two
  consecutive spaces.
- Exit codes: the launcher returns 0 when the VM started, is already running, or a dry run
  passed, in which a real start would not stop; else 1, also when another run of the launcher is
  in progress. The script that asks for administrator rights returns 0 once it has asked, also
  when the request was declined (the log says so), and 1 when another run held the lock.
  `tools\Deploy-PortableVM.ps1` returns 0 when done, 1 when it refused or failed;
  `tools\Get-StickInventory.ps1` 0 after its report, 2 when it cannot run;
  `tools\Compare-StickDryRun.ps1` 0 when the check passed, 1 when it refused or failed;
  `tools\Test-StickState.ps1` 0 when nothing needs attention, 1 when something does, 2 when it
  cannot run;
  `tools\Find-PrivateData.ps1` 0 when clean, 1 on a finding, 2 when it cannot run.
- The settings are `LauncherData\settings.psd1` in schema 2; `examples\settings.example.psd1`
  lists every key with its default.
- `Launcher` holds code only, which each deploy replaces; `LauncherData` holds what the launcher
  keeps between runs, which a deploy leaves alone.
- `<file>.pvm-tmp` and `<file>.pvm-old` beside a file are the copies of a write that did not
  finish; the launcher and the deploy tool stop at them and name the step to take.

## Known limits

The redesign removes these. Until then:

- **Never boot the stick another way while the VM is suspended or saved.** The resume would
  write the VM's old view of the disk over what changed in between, which can corrupt the
  guest's file system. Resume the VM through the launcher and shut the guest down first.
- **Start and resume the VM only through the launcher**, never from the VMware or VirtualBox
  window or library. Between runs the descriptor still names the disk number of the last run,
  which another disk may have by then.
- **VirtualBox: keep "Use Host I/O Cache" on** for the controller that holds the raw disk. With
  it off, VirtualBox takes every volume of the stick offline, the Data partition included.
- `HideDataPartition = $false` shows the Data partition to a VirtualBox guest. Never mount it
  inside the guest: Windows writes to it at the same time, and it holds the VM's own files.
- A second double-click while Windows still asks for administrator rights for the first one, or
  in the second after that, asks again. That second run then stops, saying that another run is in
  progress, or says that the VM is already running. Right after a start in VMware, before
  VMware's process for the VM shows, it can also find no running VM and run VMware for the VM
  again.
- The lock covers the launcher's checks and its start command, not the time the VM runs; once the
  VM's process runs, the process checks find it.
- While a run waits for the answer to its resume question, or hangs, it keeps the lock, and every
  double-click says that another run is in progress. Answer the question, or close that run's
  minimized PowerShell window; the run then ends, and the next one takes the lock.

## Development

The launcher's code is in `src`, the tools in `tools`, the tests in `tests` and the example
settings in `examples`. CI runs PSScriptAnalyzer 1.25.0 over these folders and Pester 6.2.0 in
Windows PowerShell 5.1, then the privacy scan over the tracked files in Git Bash. It also runs
the tests in PowerShell 7 on Windows and on Linux; on Linux it leaves out those tagged
`WindowsOnly`. The tests mock everything that reads the PC, so they never touch a disk or a VM.
Locally:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
pwsh -NoProfile -File .\tests\run-checks.ps1
sh .githooks/privacy-scan --tracked
```

In PowerShell 7 on Windows, `run-checks.ps1` uses the pinned Pester and PSScriptAnalyzer that
are installed for Windows PowerShell, so one install serves both. When a pinned module is
installed nowhere, it stops and prints the one `Install-Module` line that installs it for the
current user.

This checks that no value of the real settings file or the privacy denylist is in git's index
or history:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Find-PrivateData.ps1 -History
```

A pull request that changes the launcher is checked on the stick before it is merged. The first
part of that check is one command, run from the clone at the pull request's pushed commit, with
the stick plugged in and no VM running:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Compare-StickDryRun.ps1 -Target X:\
```

It asks for administrator rights, deploys the clone between two dry runs and compares them. It
ends with `RESULT: PASSED` or `RESULT: FAILED - <reason>`;
[docs/stick-tests.md](docs/stick-tests.md) says how to read it.

To see how the stick stands at any time, without changing anything and without administrator
rights, run the read-only check:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Test-StickState.ps1 -Target X:\
```

It reports whether the settings pass, whether the stick is the configured one, writes that did
not finish, the VM files and their copies, whether each disk file points at the stick, saved
states and the last run in the log, by kinds and counts only. It ends with `RESULT: OK`,
`RESULT: ATTENTION - <what>` or `RESULT: FAILED - <reason>`.

[CONTRIBUTING.md](CONTRIBUTING.md) describes the workflow and the git hooks,
[SECURITY.md](SECURITY.md) the trust model, and [docs/stick-tests.md](docs/stick-tests.md) how
behaviour that needs a real raw disk is tested.

## Licence

MIT, see [LICENSE](LICENSE).
