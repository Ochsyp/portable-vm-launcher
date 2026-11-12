# Tests on the test bed and the stick

Some behaviour shows only with a real raw disk: what a hypervisor does with a ZERO extent,
whether it takes volumes offline, and what happens when a descriptor names a disk that is gone.
Such tests run in this order, and a step starts only after the one before it passed:

1. **Scratch VMs** on the development PC, with no raw disk, for hypervisor settings such as
   `suspend.disabled`.
2. **A VHDX test disk.** Create a small, fixed-size VHDX in Disk Management (*Action > Create
   VHD*), initialise it as MBR and partition it like a stick: a small partition for the guest,
   then an NTFS Data partition. Attach it with `Mount-DiskImage` in an elevated PowerShell;
   Windows then gives it a `PhysicalDriveN` like a USB disk. Detach it with
   `Dismount-DiskImage` when done.
3. **The stick, without changes to the VM:** `-DryRun` runs (the README gives the command; a
   dry run still adds its lines to the launcher's log, `LauncherData\logs\launcher.log` from
   phase 3 on; from phase 4 on a full or old-format log is moved aside as
   `launcher-<date>-<time>.log`, and lines are compared after their prefix, which ends at the
   first two consecutive spaces, without the `Timings:` lines), and reading the VM files without
   changing them.
4. **The stick, one gated write at a time**, after a copy of its config text files (settings,
   `.vmx`, `.vbox`, `VirtualBox.xml` and the descriptors) is in a folder on the PC outside the
   repository.

## Phase 1 checks

Phase 1 moves the launcher's logic into a module without changing a decision. Before its pull
request is merged, on each PC the stick is used on, with `X:` as the stick's Data partition:

1. Run the read-only inventory from the clone and keep its output for the pull request; it
   holds only check names and yes, no or unknown:

   ```text
   powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Get-StickInventory.ps1 -Root X:\
   ```

2. With the launcher still on the stick as before, run a dry run (the README gives the command)
   and keep the lines it adds to `Launcher\launcher.log`, on the PC outside the repository.
3. Deploy the phase 1 launcher (README, *Install or update*) and run the same dry run. Its lines
   must match those of step 2, apart from the timestamps, the new version line, and the VM's
   old name in the start line and the messages, which phase 0 replaced with neutral names.
4. Start the VM once through `Start VM.cmd` in each hypervisor, then shut the guest down.

If a step fails, put the previous launcher back as the README says, and describe what happened
in the pull request.

## Phase 3 checks

Phase 3 moves the settings, the log and the launcher's backups into `LauncherData`, migrates the
settings to schema 2 and checks them. Before its pull request is merged, with `X:` as the
stick's Data partition and `X:\` standing for the folder that holds `Launcher`:

1. Copy the stick's config text files to a folder on the PC outside the repository, run the
   inventory and keep its answers, and list the `*.orig` and `*.launcher-backup` files beside
   the VM files.
2. With the phase 2 launcher still on the stick, run a dry run in each hypervisor (set
   `Hypervisor` for the second one and put the file back afterwards), and keep the lines they
   add to `Launcher\launcher.log`.
3. Move `Launcher.previous` aside, since a deploy refuses while it exists, then run the
   migration with `-WhatIf` (README, *Install or update*). Its plan must count the copies listed
   in step 1, and the stick must be unchanged. Then record the hash of every file below `X:\`,
   so that step 6 can show that nothing was lost.
4. Run the migration without `-WhatIf`. `Launcher` must hold only the code, `VERSION` and
   `SHA256SUMS`.
5. Compare: `LauncherData\settings.psd1` must hold the old values plus `SchemaVersion = 2` (and
   the names, if given) and pass the checks; the old settings file must be byte-identical in
   `Launcher.previous` and in `LauncherData\backups\legacy\Launcher`.
6. Every file recorded in step 3 must be at its old path with the same hash, or at the path the
   migration gave it: a moved descriptor copy differs only in its disarmed device names.
7. Run the dry runs of step 2 again. Their lines must land in `LauncherData\logs\launcher.log`,
   nothing new may appear in `Launcher`, and they must match step 2 apart from the timestamps,
   the version line and the VM's and the guest's names.
8. Run the inventory again: `LauncherData` and its log found, settings of schema 2, no settings
   file in `Launcher`, no descriptor `.orig` copy and no `.launcher-backup` copy beside the VM
   files, legacy copies in `LauncherData`, none of them naming a raw device; every other answer
   as in step 1.
9. Start the VM once through `Start VM.cmd`, then shut the guest down from inside it.

If the migration stops before the code swap (`Launcher\VERSION` is still the old one), the old
launcher keeps working: remove what the message names, if anything, and run the same command
again. Renaming `LauncherData` puts the stick back only when the migration stopped before it
moved anything; after that, the log and the copies it moved are in `LauncherData\logs` and
`LauncherData\backups\legacy`, the descriptor copies disarmed, and have to be moved back by
hand. After the swap, go back as the README says.

## Phase 4 checks

Phase 4 adds the run lock, the new log format and rotation, and dry runs that take a real start's
decisions. Before its pull request is merged:

A. On a scratch copy on the PC, never the stick: copy `src\Start-PortableVM.ps1` and
   `src\PortableVM.psm1` of the branch to `Launcher` in a temporary folder, beside an empty
   `LauncherData`. Every run there stops at the missing settings before it reads a disk, so a Yes
   in a UAC prompt starts nothing.
   1. Run the scratch script from a normal PowerShell and answer No to the UAC prompt: the
      warning shows, and the scratch log holds the request line and a `STOPPED:` line with
      `Error detail:` lines, all under one process ID.
   2. The same, answering Yes: after the request line, the elevated run logs its start, the stop
      at the missing settings, `Timings:` and `----- End: exit code 1 -----` under another
      process ID.
   3. Hold `Global\PortableVM-Launcher` in an elevated PowerShell
      (`$m = [System.Threading.Mutex]::new($false, 'Global\PortableVM-Launcher'); $m.WaitOne(0)`).
      Then the scratch script from a normal PowerShell shows the busy message without a UAC
      prompt and exits with 1, and an elevated scratch dry run stops as busy. After
      `$m.ReleaseMutex(); $m.Dispose()` the dry run stops at the missing settings again.
   4. A scratch dry run from a normal PowerShell stops with "A dry run needs administrator
      rights" and exit code 1, without a UAC prompt.
   5. With the scratch `launcher.log` set read-only, an elevated scratch dry run stops with "The
      launcher cannot write its log ..." and exit code 1, and the file stays unchanged.
B. On the stick, from an elevated PowerShell, with VirtualBox closed for a minute before:
   1. With the phase 3 launcher still on the stick, copy the config text files outside the
      repository, run the inventory, run a dry run in each hypervisor (set `Hypervisor` for the
      second one and put the file back), and keep their lines and exit codes outside the
      repository; then record the hash of `LauncherData\logs\launcher.log`.
   2. Deploy phase 4 (README, *Install or update*).
   3. Run the same dry runs. The first one moves the old log aside as
      `launcher-<date>-<time>.log`, with the hash of step 1, and says so after its version line.
      Every line of the new log has the new prefix, with one process ID per run. After dropping
      the prefixes and the `Timings:` lines, each run's lines equal those of step 1 apart from the
      version line, that note, the End line and a wait line, if VirtualBox's background service
      ran. The exit code is 0, or 1 exactly when a "would stop here" line is there. `Launcher`
      matches its `SHA256SUMS`, and no VM config file changed.
   4. A dry run from a normal PowerShell logs only its start and version lines, the stop for
      missing administrator rights, `Timings:` and the End line with exit code 1.
   5. Run the inventory again: every answer as in step 1.

No real start is needed for phase 4.

## Rules for the real stick

- Never switch VirtualBox's host I/O cache off for the stick's controller.
- Never pull the stick while a VM runs.
- Never boot the stick another way while the VM is suspended or saved.
- Never run a test on the stick before it passed on the VHDX test disk.

## Recording results

A phase that needs such a test lists it in its pull request, under "Checks on the test bed or
the stick", and the result goes there: pass or fail, and what was seen, in words. Never paste
disk numbers, signatures, UUIDs, sizes, paths or log lines from a real stick.
