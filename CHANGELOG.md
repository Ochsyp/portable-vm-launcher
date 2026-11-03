# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). There are no releases yet.

## [Unreleased]

### Added

- The launcher as it ran before the redesign: `Start VM.cmd` and
  `Launcher\Start-PortableVM.ps1`. Its messages, the message box title and the log's start
  line use neutral names; what it checks and does is unchanged.
- `Launcher\settings.example.psd1`, whose placeholders match no disk, so the launcher stops at
  its identity check until real values are filled in.
- `LICENSE` (MIT).
- `.gitattributes`, which stores text with LF and checks PowerShell and batch files out with
  CRLF, and `.gitignore`, which keeps real settings and copies of them, logs, the launcher's
  backups, VM files and disk images out of the repository.
- CI on `windows-latest`: PSScriptAnalyzer 1.25.0 and Pester 6.2.0 through
  `tests\run-checks.ps1`, then the privacy scan over the tracked files. Analyzer findings in
  `Launcher` are counted but do not fail the run yet.
- `tests\Repo.Tests.ps1`: no private files tracked, text stored with LF, ASCII sources, the
  launcher parses in Windows PowerShell 5.1, the example settings have exactly the keys the
  launcher reads, and the privacy guard rails refuse what they should.
- `.githooks/privacy-scan`, which refuses identifiers, private addresses, home paths, e-mail
  addresses and denylisted strings in the contents and names of the files.
- `tools\Find-PrivateData.ps1`, which looks for the values of the real settings file and the
  denylist in git's index and, with `-History`, in every commit, commit message, file name and
  ref name. It prints where, never the value, and exits 0 when clean, 1 on a finding and 2 when
  it cannot run.
- Git hooks: `pre-commit` refuses commits on `main` and runs `privacy-scan` on the staged
  files; `pre-push` refuses pushes to `main` and, when the settings file or the denylist exists,
  runs `tools\Find-PrivateData.ps1 -History`.
- gitleaks with the rules of `privacy-scan`, Dependabot for the pinned GitHub Actions, a pull
  request template, and the README, SECURITY.md, CONTRIBUTING.md and `docs\stick-tests.md`.

[Unreleased]: https://github.com/Ochsyp/portable-vm-launcher/commits/main
