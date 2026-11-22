# Agent guidance

- **Installing for a user:** follow [docs/AGENT-INSTALL.md](docs/AGENT-INSTALL.md). Do not install from a source checkout unless the user asks.
- **Contributing:** read [CONTRIBUTING.md](CONTRIBUTING.md) and [STATE.md](STATE.md) first.

## Project layout

- `src/`: Rust helper (`copilot-terminal-restore.exe`): state store, hook ingestion, process-identity checks.
- `shell/`: PowerShell module loaded from the user's profile; resumes conversations and detects deliberate return to the shell.
- `scripts/`: installer, uninstaller, environment check, packaging. They ship in the release ZIP, so they must not depend on the source layout.
- `tests/`: Rust integration tests (`core.rs`) and auth-free PowerShell suites. `Invoke-LifecycleProbe.ps1` is an opt-in live probe that needs an authenticated Copilot CLI and creates real conversations; never run it in CI or without the user's consent. `Measure-ProbeStartup.ps1` and `Invoke-ThemeImportTests.ps1` are manual diagnostics, not part of the suite.

## Validation

Windows only. Rust 1.100+ (MSVC) and PowerShell 7.4+. Run the commands in the README's **Development and validation** section; `cargo build --release --locked` must run before the PowerShell suites. CI (`.github/workflows/windows.yml`) also reruns the PowerShell suites on 7.4.22.

## Rules

- Never touch the developer's real installation, profile, hooks or Terminal settings from tests. Use isolated temporary roots, as the existing suites do.
- Keep `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in scripts. Escape generated profile paths with `CodeGeneration.EscapeSingleQuotedStringContent`.
- Keep the Cargo, module manifest and binary versions in sync; `Build-Package.ps1` enforces this.
- Packaging uses explicit file lists. If you add a shipped file, update `Build-Package.ps1` and `tests/Invoke-PackageTests.ps1` together.
- Never commit runtime state, logs, profile backups or real conversation IDs. Use synthetic fixtures.
- Add a focused regression test for each behavior change.
