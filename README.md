# portable-vm-launcher

[![CI](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml/badge.svg)](https://github.com/Ochsyp/portable-vm-launcher/actions/workflows/ci.yml)

A Windows launcher for a VM that lives on a USB stick and boots that stick as its disk. Plug
the stick into a Windows PC that has VMware Workstation or VirtualBox, double-click
`Start VM.cmd`, and the launcher starts the VM in whichever of the two is installed.

> **Status:** this is the launcher as it ran before its redesign, imported with neutral names.
> A hardening redesign follows in small pull requests. Until it lands, follow the rules under
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
  holds a saved or suspended state.

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
| `Launcher\Start-PortableVM.ps1` | The launcher script |
| `Launcher\settings.psd1` | Your settings, copied from `settings.example.psd1` |
| `Launcher\launcher.log` | The log of every run |
| `VMware\` | The VMware VM (`.vmx`) and its raw-disk descriptor |
| `VirtualBox\` | The VirtualBox home: `VirtualBox.xml`, the VM folder and its descriptor |

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1.
- VMware Workstation or VirtualBox 7 on each PC where the stick is used.
- Administrator rights on that PC.

## Settings

Copy `Launcher\settings.example.psd1` to `Launcher\settings.psd1` and fill it in; its comments
say how to read each value. The example's placeholders match no disk, so the launcher stops at
its identity check until the real values are in.

## Known limits

The redesign removes these. Until then:

- **Never boot the stick another way while the VM is suspended or saved.** The resume would
  write the VM's old view of the disk over what changed in between, which can corrupt the
  guest's file system. Resume the VM through the launcher and shut the guest down first.
- **Turn off suspend in VMware.** With VMware closed and no suspended state, add
  `suspend.disabled = "TRUE"` to the `.vmx`. A later version of the launcher requires it.
- **Start and resume the VM only through the launcher**, never from the VMware or VirtualBox
  window or library. Between runs the descriptor still names the disk number of the last run,
  which another disk may have by then.
- **VirtualBox: keep "Use Host I/O Cache" on** for the controller that holds the raw disk. With
  it off, VirtualBox takes every volume of the stick offline, the Data partition included.
- `HideDataPartition = $false` shows the Data partition to a VirtualBox guest. Never mount it
  inside the guest: Windows writes to it at the same time, and it holds the VM's own files.
- A missing or renamed `.vmx` or `.vbox` counts as "no saved state".

## Development

CI runs PSScriptAnalyzer 1.25.0 and Pester 6.2.0 in Windows PowerShell 5.1, then the privacy
scan over the tracked files in Git Bash. Locally:

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
