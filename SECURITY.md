# Security policy

portable-vm-launcher has a single maintainer.

## Reporting a problem

Report a vulnerability privately through the repository's Security tab (*Report a
vulnerability*). Do not open a public issue for it. Never paste a real `settings.psd1`,
`launcher.log`, `launcher-*.log`, `.vmx`, `.vbox` or `VirtualBox.xml` into issues, pull requests
or commits: they identify one stick and the PCs it was used on.

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
- Any program on the PC, under any account, can create or hold the launcher's lock
  (`Global\PortableVM-Launcher`) and so keep it from starting the VM; it cannot make the launcher
  start anything.

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

## Automated checks

- `.githooks/privacy-scan` checks the contents and names of the staged files before every
  commit for UUIDs that do not start with the synthetic `5ca1ab1e`, VMware UUIDs, MAC addresses,
  private IPv4 and IPv6 addresses, `.lan` host names, user home paths, e-mail addresses other
  than GitHub no-reply ones, and the strings in the untracked `.git/info/privacy-denylist`.
- When a real settings file (`LauncherData\settings.psd1` or the older `Launcher\settings.psd1`)
  or the denylist exists, `.githooks/pre-push` runs `tools\Find-PrivateData.ps1 -History`. It
  looks for their values, the VM's and the guest's names included, in the contents and names of
  the files in git's index and in the whole history, in commit messages and in ref names.
- gitleaks scans the commits of every push and pull request, and the whole history when the
  workflow is started by hand (`.github/workflows/secret-scan.yml`), with the rules of
  privacy-scan repeated in `.gitleaks.toml`. It cannot know the denylist or the settings file.
- `.github/workflows/ci.yml` runs PSScriptAnalyzer, the Pester tests and the privacy scan on
  `windows-latest`. The tests mock every read of the PC, and `tests\Repo.Tests.ps1` checks that
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
- Dependabot keeps the pinned GitHub Actions up to date.
