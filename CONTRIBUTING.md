# Contributing

Every change reaches `main` through a pull request, so that it is reviewed before it is
merged. This holds for the maintainer too.

## Workflow

1. Start from an up-to-date `main` and create a branch for the change:
   - `phase/<n>-<slug>` for a phase of the redesign, for example `phase/2-suspend-guard`;
   - `fix/<slug>`, `feat/<slug>`, `docs/<slug>` or `chore/<slug>` for anything else.
2. Commit on that branch. Commit messages follow
   [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), for example
   `fix: refuse a .vmx without suspend.disabled`.
3. Add an entry for the change under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), on
   the same branch.
4. Run the checks described in the README's Development section.
5. Push the branch and open a pull request against `main`. CI and the secret scan run on it.
6. Start the next phase only after the pull request is reviewed and merged. Its branch starts
   from the updated `main`.

One pull request holds one phase or one change. Only released versions reach a stick: a
release pull request moves the Unreleased entries under a new version, and the maintainer tags
it (`vX.Y.Z`) and publishes the release.

## Guard rails

`main` is never committed to or pushed to directly. GitHub does not enforce this for this
repository, so git hooks in `.githooks` enforce it on each clone:

- `pre-commit` refuses a commit while `main` or `master` is checked out, then runs
  `privacy-scan` on the staged files;
- `pre-push` refuses a push to `main` or `master`, then, when `Launcher\settings.psd1` or
  `.git/info/privacy-denylist` exists, runs `tools\Find-PrivateData.ps1 -History`.

Turn them on once after cloning:

```text
git config core.hooksPath .githooks
```

Do not bypass them with `--no-verify`. After a pull request is merged, bring the local `main`
up to date with `git switch main` and `git pull --ff-only`.

## Test data

Never commit a real `settings.psd1`, `launcher.log`, `.vmx`, `.vbox`, `VirtualBox.xml` or
descriptor, or any value read from a real disk or VM, and keep copies of a stick's files outside
the repository. Examples and fixtures use made-up values, and UUIDs start with `5ca1ab1e`,
which `privacy-scan` and the secret scan let through. Code,
docs and messages use neutral names ("the VM", "the guest"), never the name of a real VM. A
value with no recognisable shape, such as a disk signature or a VM name, can be listed in the
untracked `.git/info/privacy-denylist`, so that `privacy-scan` refuses it too.

## Tests on the stick

Behaviour that needs a real raw disk is tried on scratch VMs and a VHDX test disk first, and on
the stick only after that. [docs/stick-tests.md](docs/stick-tests.md) describes the order and
the rules.
