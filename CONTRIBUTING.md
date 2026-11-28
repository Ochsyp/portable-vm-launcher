# Contributing

portable-vm-launcher starts a VM from a USB stick in VMware Workstation or VirtualBox, and one
maintainer runs it. It follows the repository standard (`.github/standard/README.md`).

<!-- standard:begin workflow -->
## Workflow

Every change reaches `main` through a pull request that the maintainer reviews and merges. This
holds for the maintainer too.

1. Branch from an up-to-date `main`: `phase/<n>-<slug>` for a phase of the plan, or `fix/`,
   `feat/`, `docs/` or `chore/` plus a short slug.
2. Write commit messages and the pull request title as Conventional Commits (`feat:`, `fix:`,
   `docs:`, `chore:`, `ci:`, `test:`, `refactor:`).
3. Add a line under `## [Unreleased]` in `CHANGELOG.md`. Three kinds of pull request add none
   there: a release pull request (`chore/release-X.Y.Z`), which moves the lines into the new
   version; the fix of a draft release (`fix/release-X.Y.Z-<slug>`), whose line goes into that
   version's section; and a Dependabot pull request, whose updates the next release pull request
   sums up.
4. Run the checks in Checks below, and fix what they find.
5. Push the branch and open a pull request against `main`. Before every `gh pr create` and
   `gh pr edit`, run `.github/standard/bin/pr-text` on the title and the body: it refuses
   denylist terms and rule pack hits, and never prints them.
6. Start the next phase only after the pull request is merged.

One pull request holds one phase or one change.

Repository work happens only on a machine with the maintainer's git configuration, never in a
hosted environment such as a codespace or a cloud workspace. That configuration turns the hooks
on and loads the denylists for every clone of this repository's GitHub URL. A clone made from a
local path gets no hooks, so run `git config core.hooksPath .githooks` in it right after cloning.

An outside contributor's pull request is reviewed in the browser and through CI. Hooks run from
the checked-out tree with the maintainer's credentials, even during a fetch, so:
- never check out a fork's pull request branch in a clone with the hooks on;
- clone a fork only with `git clone <fork URL>` or `gh repo clone <fork> <folder> --no-upstream`,
  into a scratch folder, and never add a remote for this repository there.
<!-- standard:end workflow -->

<!-- standard:begin guard-rails -->
## Guard rails

GitHub's ruleset on `main` blocks direct pushes, force pushes and its deletion, and the merge
of a pull request whose `all-passed` or `scan` check failed.

The hooks in `.githooks/` guard every commit and push:
- `pre-commit` refuses a commit while `main` or `master` is checked out. It also refuses a changed
  copy of the standard, a staged file above `MAX_BLOB_KB`, and staged content, path names, author
  or committer that hold a denylist term or a rule pack hit. `pre-merge-commit` does the same for
  a merge.
- `commit-msg` refuses such a term or hit in the message.
- `pre-push` refuses a push to `main` or `master`, and a branch or tag name with a term or hit. It
  refuses every tag push except a `v*` tag under `RELEASE_KIND=legacy`; otherwise release tags
  come from publishing a release. It also refuses a term or hit in what the pushed commits bring
  in, which covers rebase, cherry-pick and `am` too.

The denylists hold names that must never be committed and never leave the maintainer's machine.
The rule packs in `.githooks/rules/` hold the patterns: private addresses, local host names, MAC
addresses, home paths and e-mail addresses, and disk and VM identifiers where the config enables
them. A refusal names the file, the line and the kind of finding, never the value.

The maintainer's git configuration turns the hooks on for every clone of this repository's GitHub
URL. Anywhere else, such as a clone made from a local path, turn them on once after cloning:
`git config core.hooksPath .githooks`. Never use `--no-verify`.
<!-- standard:end guard-rails -->

<!-- standard:begin standard -->
## The repository standard

Files listed in `.github/standard/MANIFEST` are copies of the repository standard. Never edit
them here: change repo-standard, release it, and sync with a `chore/standard-X.Y.Z` pull request.
CI fails when a copy differs or changes on another branch. An exemption, an accepted finding or a
dropped check comes in a `chore/privacy-*` pull request of its own.

When a private repository goes public, it does so in this order. A pull request sets
`VISIBILITY=public`, and `tools/sync` writes the public block texts into it. The maintainer
switches the repository to public on GitHub and turns on the security settings and the ruleset
those texts promise. A new commit on that branch reruns its checks; a rerun from the Actions page
keeps the old private flag. Then that pull request merges before anything else: until it does,
`main` says private while GitHub says public, and CI on `main` and `tools/status` fail.
<!-- standard:end standard -->

## Checks

```text
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
pwsh -NoProfile -File .\tests\run-checks.ps1
sh .githooks/privacy-scan --tracked
sh .github/standard/bin/standard-check --local
```

`tests\run-checks.ps1` runs PSScriptAnalyzer and the Pester tests with the versions that
`.github/standard/bin/install-tools` pins. Locally a test may skip, as one does while a VM runs
on the PC; CI runs every test and fails on a skipped one (`-FailOnSkip`). `bats
.github/standard/tests/FILE.bats` runs a suite of the standard, one file at a time in Git Bash.

CI runs the standard's checks and three stages of this repository: `lint` (`ci/lint.ps1`, the
analyzer, Windows PowerShell 5.1 on Windows), `test` (`ci/test.ps1`, every test in Windows
PowerShell 5.1 and in PowerShell 7 on Windows) and `system` (`ci/system`, the tests that are not
tagged `WindowsOnly`, in PowerShell 7 on Linux). Tests tagged `DesktopOnly` or `CoreOnly` hold the
cases of one edition of PowerShell; each edition leaves out the other's.

`tools\Find-PrivateData.ps1 -History` looks for the values of the real settings file and the
denylists in git's index and the whole history; run it by hand now and then, and before a
release.

## Test data

Never commit a real `settings.psd1`, `launcher.log` or `launcher-*.log`, `.vmx`, `.vbox`,
`VirtualBox.xml` or descriptor, a `LauncherData` folder or anything from one, or any value read
from a real disk or VM, and keep copies of a stick's files outside the repository; a copy of a
stick's `LauncherData\settings.psd1` in the clone is gitignored and only feeds
`tools\Find-PrivateData.ps1`. Examples and fixtures use made-up values, and UUIDs start with
`5ca1ab1e`, which the rule packs let through. The config enables the `base`, `disk` and `vm`
packs, with no exemption and no accepted finding: synthetic values use the ranges the packs
exempt (`5ca1ab1e`, `example-`, `*.invalid`, `192.0.2.x`, `Synthetic` disk names), and a
private-looking value in a test is built from fragments at run time. Code, docs and messages use
neutral names ("the VM", "the guest"), never the name of a real VM or guest system: real names
belong only in `VmDisplayName` and `GuestName` in the stick's settings. A value with no
recognisable shape, such as a disk signature or such a name, belongs in the maintainer's
denylist too (Guard rails), never in a file of the repository.

The Pester tests build the stick's files in TestDrive and mock the module's `Invoke-Pvm*`
adapters. `tests\run-checks.ps1` sets `PVM_TEST=1`, so an adapter that a test did not mock
throws instead of reading the PC.

## Tests on the stick

Behaviour that needs a real raw disk is tried on scratch VMs and a VHDX test disk first, and on
the stick only after that. [docs/stick-tests.md](docs/stick-tests.md) describes the order and
the rules.

<!-- standard:begin releasing -->
## Releasing

GitHub Actions builds each release, and the maintainer publishes it in the browser.

1. `.github/standard/bin/release-prepare` writes the release pull request `chore/release-X.Y.Z`:
   `VERSION`, the `VERSION_COPY` files, and the `CHANGELOG.md` section with its links. Its body
   names the dependency updates since the last release. CI checks the version, the date and the
   links. For a zip, tar or stack release, the `release` workflow builds it twice and compares
   the builds.
2. The maintainer reviews and squash-merges it. The push to `main` that changes `VERSION` runs
   the `release` workflow: the checks of `ci` on that commit, the build, an attestation in the
   public repositories, and a draft release `vX.Y.Z` of that commit.
3. The maintainer checks the draft (notes, assets, target commit, image digest) and clicks
   **Publish release**. GitHub creates the tag and the immutable release. The `verify` job then
   checks the published release, and the maintainer looks for it to pass.
4. To fix a draft, merge a pull request from `fix/release-X.Y.Z-<slug>`; its `CHANGELOG.md` line
   goes into `## [X.Y.Z]`. Then run the `release` workflow on `main` (Actions, release, Run
   workflow). Merge nothing else until the draft is published: CI says so on every pull request
   while a release waits.
5. Never delete a published release. Tick **Set as a pre-release** on a bad one instead, so that
   clients and updaters ignore it, and ship X.Y.Z+1. For a container image, the tick also moves
   `latest` back.

Only the maintainer publishes a release. No one creates a release tag by hand, and no script or
automation publishes a release, or edits or deletes a published one.
<!-- standard:end releasing -->

## Release contract

A release `vX.Y.Z` holds the standard's generic archive, `portable-vm-launcher-X.Y.Z.zip`, and
`SHA256SUMS`. The archive is the tree at the tag in a folder `portable-vm-launcher-X.Y.Z/`,
without the development files that `.gitattributes` marks `export-ignore` (`.github/`,
`.githooks/`, `ci/`, `tests/`, `CONTRIBUTING.md` and the editor and git files), with the release
manifest `portable-vm-launcher-release.json` (name, version, tag and commit) added. It holds the
launcher (`src/`, `Start VM.cmd`), the tools, the example settings and the documents. A stick
gets the launcher through `tools\Deploy-PortableVM.ps1` from a clone at the release's tag; the
README's "Install or update" says how. The first release is 1.0.0, after the release audit; until
then `VERSION` ends in `-dev` and nothing is released.
