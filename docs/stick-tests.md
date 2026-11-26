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

Every check on the stick starts with the dry-run check below.

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
      prompt and exits with 1, and an elevated scratch dry run stops as busy. Start that dry run
      as a new process (`powershell -NoProfile -ExecutionPolicy Bypass -File ... -DryRun`), never
      in the PowerShell that holds the mutex: a thread may take a mutex it holds again, so there
      the dry run would not be busy. After `$m.ReleaseMutex(); $m.Dispose()` the dry run stops at
      the missing settings again.
   4. A scratch dry run from a normal PowerShell stops with "A dry run needs administrator
      rights" and exit code 1, without a UAC prompt.
   5. With the scratch `launcher.log` set read-only, an elevated scratch dry run stops with "The
      launcher cannot write its log ..." and exit code 1, and the file stays unchanged. Then
      clear the read-only attribute again.
   6. Type these lines in an elevated PowerShell. Keep a handle to the lock without taking it
      (`$k = [System.Threading.Mutex]::new($false, 'Global\PortableVM-Launcher')`), and let a new
      process take it and end without releasing it; the single quotes keep the outer PowerShell
      from expanding the `$` names
      (`powershell -NoProfile -Command '$m = [System.Threading.Mutex]::new($false, ''Global\PortableVM-Launcher''); $null = $m.WaitOne(0)'`).
      The next elevated scratch dry run, as a new process, logs that an earlier run ended without
      releasing the lock and that it took the lock over, then stops at the missing settings.
      `$k.Dispose()` ends the check.
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
      ran. The exit code is 1 exactly when a "would stop here" or `STOPPED:` line is there, else
      0. `Launcher` matches its `SHA256SUMS`, and no VM config file changed.
   4. A dry run from a normal PowerShell logs only its start and version lines, the stop for
      missing administrator rights, `Timings:` and the End line with exit code 1.
   5. Run the inventory again: every answer as in step 1.

No real start is needed for phase 4.

## Phase 5 checks

Phase 5 writes the VM files through a safe write, reads descriptors with a strict parser, fixes
drive letters at a drive root and keeps the version before the latest rewrite. It changes how the
files are written, not what a hypervisor reads, so its checks need no step on the VHDX test disk.
Before its pull request is merged, from an elevated PowerShell, with VirtualBox closed for a
minute before:

1. With the phase 4 launcher still on the stick, copy the config text files outside the
   repository, run the inventory and a dry run in each hypervisor (set `Hypervisor` for the
   second one and put the file back), and keep their lines and exit codes outside the
   repository.
2. On the PC, never the stick: let the branch's module read the copies of the two descriptors
   (`ConvertFrom-PvmDescriptorData`, then `ConvertFrom-PvmDescriptorText`). A refusal stops the
   check until it is understood, since a start would stop at it too.
3. Deploy phase 5 (README, *Install or update*). `Launcher` matches its `SHA256SUMS`, and no
   `*.pvm-tmp` or `*.pvm-old` file is below the stick folder.
4. Run the same dry runs. After dropping the prefixes and the `Timings:` lines, each run's lines
   equal those of step 1 apart from the version line and a wait line, if VirtualBox's background
   service ran, and the exit codes are the same. Any other difference stops the check until it
   is understood.
5. VMware start. Disarm the VMware descriptor in place (`ConvertTo-PvmDisarmedDescriptorText`,
   written through `Write-PvmFile` with `-Expected`), so that the start must rewrite it. Start
   the VM with `Start VM.cmd`, use the guest and shut it down from inside. The log shows the
   descriptor's `->` line, `Started with VMware Workstation` and exit code 0. Afterwards:
   - the descriptor's extent lines equal those of its step 1 copy, apart from the device names
     if Windows numbered the stick differently; any other line may differ only where VMware keeps
     its own entries (`CID` and `ddb.` lines);
   - its `.previous.orig` copy below `LauncherData\backups` equals the step 1 copy disarmed, and
     a first copy that was there before is unchanged;
   - no `*.pvm-tmp` or `*.pvm-old` file is below the stick folder.
6. VirtualBox start. Set `Hypervisor` to VirtualBox for this start and disarm the VirtualBox
   descriptor in the same way. Start the VM with `Start VM.cmd`, use the guest and shut it down
   from inside, then put the settings file back byte for byte. The log shows a drive-letter line
   for the `.vbox` file and one for `VirtualBox.xml`, then the descriptor's `->` line, `Started
   with VirtualBox` and exit code 0. Afterwards the descriptor and its copies are as in step 5,
   with VirtualBox in place of VMware; a file whose paths moved has a `.previous.launcher-backup`
   copy equal to its step 1 copy; and no `*.pvm-tmp` or `*.pvm-old` file is below the stick
   folder. VirtualBox rewrites the `.vbox` file and `VirtualBox.xml` itself while the VM runs, so
   they are not compared with step 1.
7. Run the inventory again: every answer as in step 1.

By hand, the owner starts the VM twice, and each time uses the guest and shuts it down from
inside; never pull the stick while a VM runs.

## Checks for keeping one previous launcher

The deploy now replaces the earlier launcher copy. The launcher's own code does not change, so no
VM start is needed. Repeated deploys and every failure case run on a scratch folder in the tests,
never on the stick. Before the pull request is merged, from an elevated PowerShell, with VirtualBox
closed for a minute before:

1. Record the hash of every file below the stick folder, except the launcher's log.
2. Run a VMware dry run with the launcher on the stick, and keep its lines and exit code outside
   the repository.
3. Deploy (README, *Install or update*), with nothing moved aside by hand. The report names the
   version `Launcher.previous` now holds and the version it removed.
4. Run the same dry run. After dropping the prefixes and the `Timings:` lines, its lines equal
   those of step 2 apart from the version line and a wait line, and the exit code is the same.
5. Compare with step 1: `Launcher.previous` holds the launcher that was in `Launcher`, unchanged,
   plus the `.cmd`. The older copy is gone and no `Launcher.previous.remove` is left. Every other
   file, `LauncherData` and the VM files included, has its old hash, apart from the log.

Folders named by hand are not the tool's to remove. A last, separate step, which can be skipped
and cannot be undone, removes such a folder only if it passes the same check as the deploy's own
copy, and says what it removed and what it left.

## The dry-run check of a pull request

`tools\Compare-StickDryRun.ps1` is the first part of every stick check. Run it from the clone at
the pull request's pushed commit, with the stick plugged in, VMware and VirtualBox closed and no
VM running:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Compare-StickDryRun.ps1 -Target X:\
```

`-Target` is the folder that holds `Launcher` and `LauncherData`. Without it, the tool takes the
one such folder at a drive's root or one level below. It asks for administrator rights in a
second window and prints that window's result. It starts no VM. Then it:

1. lists the stick's top folders and files and the kinds of what they hold, and saves that
   listing as `listing.txt` on the PC. A name the tool does not know shows as
   `other folder <n>` or `other file <n>`;
2. refuses, changing nothing, while a VM runs, when a write or deploy was left unfinished, when
   the clone is not clean at its pushed commit, or when the stick holds that commit already;
3. runs a dry run with the launcher on the stick, and deploys nothing if it fails;
4. deploys the clone through `tools\Deploy-PortableVM.ps1`;
5. runs the same dry run again and compares the two line by line, apart from the version line,
   the `Timings:` line, a wait line and the note on a log moved aside;
6. checks that `Launcher.previous` holds what `Launcher` held, that `Launcher` and
   `Start VM.cmd` are the clone's, that every other file has its old hash, apart from the log,
   and that the top-level names are those of the listing, apart from `Launcher.previous` and
   the launcher's `.cmd`.

The last line is `RESULT: PASSED - ...` or `RESULT: FAILED - <reason>`, with exit code 0 or 1.
The output names kinds of log lines, such as `stick found` or `using VMware`, and counts. A line
the tool does not know is an `other line`; it is still compared, so it cannot pass unnoticed. Raw
log lines stay in memory. The listing and the output are saved in a folder for each run below
`%LOCALAPPDATA%\PortableVM\stick-checks`, or below `-OutputFolder`.

What a pull request expects to change goes into `-ExpectChange`, one entry per changed line, as
the kinds of the line before and after. For a pull request that points a descriptor at the stick
where it was not:

```text
-ExpectChange 'descriptor would be pointed at the stick => descriptor already points at the stick'
```

`'=> <kind>'` expects an added line and `'<kind> =>'` a removed one. Where several lines in a row
differ, the removed and added ones pair up in order, and the output names each pair. Each
expected change must
happen, on one line per pair of dry runs at most; any other difference fails the check. Read the
listing before writing an expectation about the stick's folders: `-ListOnly` prints and saves it
and changes nothing.

`-AlsoVirtualBox` adds a second pair of dry runs with `Hypervisor` set to VirtualBox, for a pull
request that touches that path. The tool first keeps the settings' bytes in the output folder on
the PC, writes the change through the launcher's safe write, and puts the bytes back after each
VirtualBox dry run; the run folder keeps that copy. If a run is cut off in between, the next run stops and says how to put the
settings back.

The check after a VM start is not part of the tool; a pull request that needs one asks for it.

## The read-only check

`tools\Test-StickState.ps1` reads the stick with the launcher's own module and changes nothing:
it writes no file, on the stick or on the PC, and needs no administrator rights. Use it after a
VM start, before a deploy, or whenever something looks wrong:

```text
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\tools\Test-StickState.ps1 -Target X:\
```

Without `-Target` it finds the stick folder as the dry-run check does. Each line is a check and a
kind, a yes or no, or a count:

- whether the settings pass the launcher's checks, and whether the stick is the configured one
  (unknown when Windows does not say which disk it is);
- writes that did not finish, whether the next start would stop at one, and what a deploy left;
- for the VMware and VirtualBox disk files, the `.vbox` file and `VirtualBox.xml`: whether each
  is there, its first copy and the copy of the version before its latest rewrite, and whether a
  disk file's copies name no raw disk;
- whether each disk file points at the stick, and if not, why the next start rewrites it, in the
  same words as the log;
- saved states in VMware and VirtualBox;
- the last run in the log: a start or a dry run, how many days ago, the program it used, its end,
  whether it stopped, the kinds of its lines, and whether a declined request for administrator
  rights or a stop without a run came after it.

An answer the check cannot give at the moment, such as a disk file a running VM holds, is
`unknown`, and the rest of the report still shows.

It ends with `RESULT: OK - nothing needs attention`, `RESULT: ATTENTION - <what needs it>` (exit
code 1) or `RESULT: FAILED - <reason>` (exit code 2). A disk file that does not point at the stick
needs no attention, since the next start points it there.

## Rules for the real stick

- Never switch VirtualBox's host I/O cache off for the stick's controller.
- Never pull the stick while a VM runs.
- Never boot the stick another way while the VM is suspended or saved.
- Never run a test on the stick before it passed on the VHDX test disk.

## Recording results

A phase that needs such a test lists it in its pull request, under "Checks on the test bed or
the stick", and the result goes there: pass or fail, and what was seen, in words. Never paste
disk numbers, signatures, UUIDs, sizes, paths or log lines from a real stick.
