# Security policy

portable-vm-launcher has a single maintainer. It runs on Windows PCs, from a USB stick, as
administrator, and starts a VM on the stick's raw disk.

<!-- standard:begin reporting -->
## Reporting a vulnerability

Report a vulnerability through GitHub's private vulnerability reporting: the **Security** tab,
then **Report a vulnerability**. Do not open a public issue.
<!-- standard:end reporting -->

Never paste a real `settings.psd1`, `launcher.log`, `launcher-*.log`, `.vmx`, `.vbox` or
`VirtualBox.xml` into issues, pull requests or commits: they identify one stick and the PCs it was
used on.

## Trust model

- The stick must be trusted and under your physical control. The launcher runs from it as
  administrator, so whoever can write to the stick decides what runs as administrator on each
  PC it is plugged into. The launcher checks no signature or hash of its own files; only a check
  stored on each PC could, and one may follow after version 1.0.0. The execution policy does not
  change this, since anyone who can change the script can change `Start VM.cmd` as well.
- At each start through the launcher, the VM gets only a disk whose MBR signature, size,
  512-byte sectors and Data partition position match the settings, and never the PC's own
  Windows disk. The README lists the known limits of these checks.
- Raw-disk VMs need the hypervisor to run elevated. Shared folders, drag and drop and shared
  clipboards then act on the host with administrator rights, so keep them off for this VM.

## Known exposure

- Whoever can write to the stick decides what runs as administrator on each PC it is plugged
  into, as the trust model says. That is accepted: the stick stays under the owner's control.
- Any program on the PC, under any account, can create or hold the launcher's lock
  (`Global\PortableVM-Launcher`) and so keep it from starting the VM; it cannot make the launcher
  start anything.
- The guest can write the stick's boot area (the MBR and the gap before the first partition) in
  both programs, as the README's "Boot area" says.
- While the VM runs, the launcher keeps running in the background, hidden, with the
  administrator rights it was given, so that it can point the disk file away from the stick when
  the VM ends. In that time it only reads the process list and, at the end, writes that disk file
  and its copies. Task Manager lists it as Windows PowerShell; ending it there leaves the disk
  file pointed at the stick until the next start.

## Network

The launcher and its tools make no network connection. They run local programs only: VMware
Workstation, VirtualBox and its `VBoxManage`, and Windows' own commands.

## Data that stays private

- `LauncherData\settings.psd1` holds the stick's disk signature, size and partition layout, the
  VM's UUID and the names of the VM and the guest. `LauncherData\logs\launcher.log`, and the
  `launcher-<date>-<time>.log` files it moves aside, also hold disk numbers, install paths,
  process IDs, error details with paths, and times of use, and `LauncherData\backups` holds copies
  of VM files. All of `LauncherData` is gitignored; only `examples\settings.example.psd1`, with
  placeholders, is committed.
- The launcher reads the settings as data: it parses the file and accepts only plain values,
  so nothing in it runs. Whoever can write to the stick still decides what runs, as the trust
  model says.
- The VM folders hold UUIDs, MAC addresses and host details, and stay on the stick.
- The stick-check tool prints and saves kinds of log lines, counts and the deploy's own lines,
  never a raw log line. A run with `-AlsoVirtualBox` keeps a copy of the settings in its run
  folder below `%LOCALAPPDATA%\PortableVM\stick-checks`, on the PC and outside the repository.
- The stick's identifying values (its disk signature and sizes, the VMs' UUIDs and names) are in
  the maintainer's denylist, so the hooks refuse them in every commit and push.
  `tools\Find-PrivateData.ps1 -History` looks for the real settings' values and the denylists'
  terms in git's index and the whole history.

## What the tests guard

- The tests mock every read of the PC, and `tests\Repo.Tests.ps1` checks that
  no source calls a Storage command other than a read, or a CIM or WMI method, that the
  inventory tool calls nothing that writes, that the module writes files only through its safe
  write, the log aside, and deletes only the copies that write makes, and that the deploy tool
  writes files only through that safe write. The deploy tool deletes one thing: the earlier
  launcher copy that the new `Launcher.previous` replaces, and only when every file in it is what
  a deploy wrote. It never touches `LauncherData`, the VM files or any other folder. The
  stick-check tool, `tools\Compare-StickDryRun.ps1`, changes the stick only through the deploy
  tool and, with `-AlsoVirtualBox`, the safe write of the settings, and writes its own files only
  below its output folder on the PC. The read-only check, `tools\Test-StickState.ps1`, writes,
  moves, deletes and starts nothing, which `tests\Repo.Tests.ps1` checks too.

<!-- standard:begin automated-checks -->
## Automated checks

- **Secret scan.** The `secret-scan` workflow runs gitleaks (MIT, pinned by version and SHA-256,
  always with its default rules) and this repository's rule packs. It scans the commits of each
  pull request and each push to `main`, and the whole history every Monday and when run by hand.
  Positive controls run first, so a scanner that finds nothing fails. Findings are redacted.
  GitHub's secret scanning and push protection are on as well. GitHub turns the Monday run off
  after 60 days without activity in this repository; repo-standard's `tools/status` reports it.
- **Hooks.** The hooks in `.githooks/` check every commit and push on the maintainer's machine:
  content, path names, messages, ref names and identities, against the rule packs and a denylist
  that never leaves that machine. The maintainer also checks regularly, with repo-standard's
  `tools/status`, what reached GitHub, pull request texts and release notes included.
- **CI and releases.** The `ci` workflow checks the standard's copies, the privacy rules over the
  tree, the version, the changelog and the pull request, and runs the tests. The `release`
  workflow builds, attests and drafts each release, and verifies it once it is published.
- **Dependencies.** Dependabot watches the ecosystems in `.github/dependabot.yml`, with security
  updates on.

If a secret is ever committed, rotate it first, then remove it from the history.
<!-- standard:end automated-checks -->
