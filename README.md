# portable-vm-launcher

[![CI](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml)

A Windows launcher for a VM that lives on a USB stick and boots that stick as its disk. Plug
the stick into a Windows PC that has VMware Workstation or VirtualBox, double-click
`Start VM.cmd`, and the launcher starts the VM in whichever of the two is installed.

> **Status:** phase 3 of a hardening redesign. The launcher's checks and start steps live in a
> tested module; it guards against suspends and saved states, checks its settings before it
> reads the PC, and keeps its settings, log and backups in `LauncherData`, apart from its code,
> as *What it does* says. [CHANGELOG.md](CHANGELOG.md) lists every change. More small pull
> requests follow. Until they land, follow the rules under [Known limits](#known-limits).

## What it does

Before every start the launcher:

- asks for administrator rights, which a VM needs to use a physical disk;
- checks `LauncherData\settings.psd1` before it reads anything on the PC, without running
  anything in it, and names every setting that is wrong in one message;
- finds the stick's disk number on this PC and checks that it is the configured stick: MBR
  disk signature, size, 512-byte sectors and the position of the Data partition it runs from.
  Otherwise nothing starts;
- refuses the PC's own Windows disk;
- points the VM's raw-disk descriptor (`.vmdk`) at that disk number;
- fixes the stick's drive letter in the VirtualBox files;
- refuses to start the VM in one hypervisor while it runs in the other, or while the other
  holds a saved or suspended state;
- refuses to start the VM in VMware unless its `.vmx` has `suspend.disabled = "TRUE"` and
  `uuid.action = "keep"`, and says which line to add;
- asks before it resumes a saved state: any VirtualBox save, or a VMware suspend from before
  `suspend.disabled` was set, which VMware still resumes. No is the default answer, and
  `SavedStatePolicy = 'Refuse'` in the settings makes the launcher stop instead;
- stops when it cannot tell whether the VM is saved, because its `.vmx` or `.vbox` is missing or
  cannot be read, the `.vmx` lacks `config.version` or sets a safety key twice, or the `.vbox` is
  no valid XML.

VMware always gets the stick with the Data partition blanked, because Windows keeps using that
partition while the VM runs. For VirtualBox, the `HideDataPartition` setting decides.

Messages and the dialog title name the VM and the guest system as `VmDisplayName` and
`GuestName` in the settings say; without them they say "the VM" and "the guest". Before the
launcher rewrites a VM file for the first time, it keeps that first version below
`LauncherData\backups`; a copy of a raw-disk descriptor names a disarmed device there, so
opening it by mistake reaches no disk.

`-DryRun` runs every check and logs what would change, without changing a VM file or starting
anything; it still adds its lines to `LauncherData\logs\launcher.log`. Run it from an elevated
PowerShell, so the checks see what a real start sees, with `X:` as the stick's Data partition:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File X:\Launcher\Start-PortableVM.ps1 -DryRun
```

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
| `LauncherData\logs\launcher.log` | The log of every run |
| `LauncherData\backups\` | The first version of each file the launcher rewrites, at its path below the stick folder; descriptor copies are disarmed |
| `LauncherData\backups\legacy\` | What `-MigrateSettings` moved there: the old settings file and the copies the launcher used to keep beside the VM files |
| `Launcher.previous\` | The launcher that the last deploy replaced |
| `VMware\` | The VMware VM (`.vmx`) and its raw-disk descriptor |
| `VirtualBox\` | The VirtualBox home: `VirtualBox.xml`, the VM folder and its descriptor |

The table's paths can also lie in a folder below the drive's root; `Launcher` and
`LauncherData` sit side by side in it, and the path settings start from it.

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
the VM folders stay as they are. The tool deletes nothing, so remove or move away
`Launcher.previous` before the next deploy. `-WhatIf` runs the checks only.

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
so the old launcher works until then. If the migration stops, remove what its message names, if
anything, and run the same command again: it keeps the `LauncherData\settings.psd1` it wrote,
with any change made to it since, and moves what is left, also a log or copy that the old
launcher wrote in between.

To go back, rename `Launcher` to any other name, rename `Launcher.previous` to `Launcher`, and
move the old `.cmd` from it back to the stick's root. After a migration, `Launcher.previous`
still holds the old settings file, so the old launcher finds it; `Start VM.cmd` can stay.

## Public interface

What a stick, a script or a user may rely on between versions:

- `Start VM.cmd` at the stick folder starts the launcher; `Launcher\Start-PortableVM.ps1
  -DryRun` runs every check without changing or starting anything.
- Exit codes: the launcher returns 0 when the VM started, is already running or a dry run
  passed, else 1; `tools\Deploy-PortableVM.ps1` 0 when done, 1 when it refused or failed;
  `tools\Get-StickInventory.ps1` 0 after its report, 2 when it cannot run;
  `tools\Find-PrivateData.ps1` 0 when clean, 1 on a finding, 2 when it cannot run.
- The settings are `LauncherData\settings.psd1` in schema 2; `examples\settings.example.psd1`
  lists every key with its default.
- `Launcher` holds code only, which each deploy replaces; `LauncherData` holds what the launcher
  keeps between runs, which a deploy leaves alone.

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

## Development

The launcher's code is in `src`, the tools in `tools`, the tests in `tests` and the example
settings in `examples`. CI runs PSScriptAnalyzer 1.25.0 over these folders and Pester 6.2.0 in
Windows PowerShell 5.1, then the privacy scan over the tracked files in Git Bash. The tests mock
everything that reads the PC, so they never touch a disk or a VM. Locally:

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
sh .githooks/privacy-scan --tracked
```

This checks that no value of the real settings file or the privacy denylist is in git's index
or history:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Find-PrivateData.ps1 -History
```

[CONTRIBUTING.md](CONTRIBUTING.md) describes the workflow and the git hooks,
[SECURITY.md](SECURITY.md) the trust model, and [docs/stick-tests.md](docs/stick-tests.md) how
behaviour that needs a real raw disk is tested.

## Licence

MIT, see [LICENSE](LICENSE).
