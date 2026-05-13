# TODO

## Critical
- [x] Add `.gitignore` for PowerShell logs/temp files, Windows artifacts, IDE folders, local MSI packages, secrets, certificates, and key files.
- [x] Add `README.md` with purpose, prerequisites, required parameters, examples, offline MSI usage, proxy mode, and verification notes.
- [x] Add CI/CD pipeline for PowerShell validation and secret scanning.

## Warning
- [x] Use Conventional Commits from the initial commit onward.
- [x] Add `CHANGELOG.md` if this installer will be versioned or released.
- [x] Add `PSScriptAnalyzerSettings.psd1` and run PSScriptAnalyzer in CI.
- [x] Add focused Pester tests where behavior can be tested without a real Windows/Zabbix target.
- [x] Add secret scanning with `gitleaks`, `git-secrets`, or equivalent.

## Info
- [x] Add `.editorconfig` for consistent line endings and indentation across `.ps1`, `.cmd`, and Markdown files.
- [x] Consider replacing manual launcher edits with documented examples or parameter files if deployments become repetitive.

## Verification Gaps
- [x] Verify GitHub branch protection after the first `main` branch is pushed.
- [x] Verify PowerShell syntax/static checks after installing `pwsh` locally.
