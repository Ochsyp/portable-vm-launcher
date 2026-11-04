# portable-vm-launcher

[![CI](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml)

A Windows launcher for a VM that lives on a USB stick and boots that stick as its disk. Plug
the stick into a Windows PC that has VMware Workstation or VirtualBox, double-click
`Start VM.cmd`, and the launcher starts the VM in whichever of the two is installed.

> **Status:** phase 2 of a hardening redesign. The launcher's checks and start steps live in a
> tested module, and the launcher now guards against suspends and saved states, as *What it does*
> says; [CHANGELOG.md](CHANGELOG.md) lists every change. More small pull requests follow. Until they land, follow the rules under
> [Known limits](#known-limits).

## What it does

Before every start the launcher:

- asks for administrator rights, which a VM needs to use a physical disk;
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

`-DryRun` runs every check and logs what would change, without changing a VM file or starting
anything; it still adds its lines to `Launcher\launcher.log`. Run it from an elevated
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
| `Launcher\Start-PortableVM.ps1` | The script `Start VM.cmd` starts |
| `Launcher\PortableVM.psm1` | The launcher's checks and start steps |
| `Launcher\VERSION`, `Launcher\SHA256SUMS` | The deployed version and the hashes of its code, written by the deploy tool |
| `Launcher\settings.psd1` | Your settings, copied from `examples\settings.example.psd1` |
| `Launcher\launcher.log` | The log of every run |
| `Launcher.previous\` | The launcher that the last deploy replaced |
| `VMware\` | The VMware VM (`.vmx`) and its raw-disk descriptor |
| `VirtualBox\` | The VirtualBox home: `VirtualBox.xml`, the VM folder and its descriptor |

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1.
- VMware Workstation or VirtualBox 7 on each PC where the stick is used.
- Administrator rights on that PC.

## Settings

Copy `examples\settings.example.psd1` from this repository to `Launcher\settings.psd1` on the
stick and fill it in; its comments say how to read each value. The example's placeholders match
no disk, so the launcher stops at its identity check until the real values are in.

## Install or update

`tools\Deploy-PortableVM.ps1` copies the launcher from a clone of this repository to a stick,
with `X:` as the stick's Data partition:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Deploy-PortableVM.ps1 -Target X:\
```

It needs `Launcher\settings.psd1` on the stick and refuses while a VM runs on the PC. It builds
the new launcher in `Launcher.new` and checks every copy against the clone before it changes
anything. Then the old `Launcher` becomes `Launcher.previous`, an older launcher `.cmd` at the
stick's root moves in there too, and `Start VM.cmd` takes its place. Your settings and log come
along, and the VM folders stay as they are. The tool deletes nothing, so remove or move away
`Launcher.previous` before the next deploy. `-WhatIf` runs the checks only.

To go back, rename `Launcher` to any other name, rename `Launcher.previous` to `Launcher`, and
move the old `.cmd` from it back to the stick's root.

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
