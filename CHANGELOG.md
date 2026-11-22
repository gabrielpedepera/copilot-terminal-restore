# Changelog

## 0.1.0 (prerelease)

- Windows x64 exact-ID recovery in ordinary Windows Terminal tabs.
- Native lifecycle tracking and immediate ownership registration for idle automatic resumes.
- PowerShell startup/prompt integration, deliberate-exit disarming, and per-tab synchronization.
- Portable per-user installation, backups, rollback, diagnostics, and uninstall.
- Native Terminal setup instructions and optional plain-PowerShell cwd reporting (`Install.ps1 -EnableDirectoryReporting`).
- Installable ZIP, checksums, dependency notices, and auth-free Windows validation.
- Agent installation runbook (`docs/AGENT-INSTALL.md`) and contributor guidance for AI agents (`AGENTS.md`).
- Runbook included in the ZIP, tagged downloads, enforced checksum verification, and native launcher/post-install enrollment guidance.
- Isolated Rust test directories remain independent when parallel fixtures share a clock timestamp.

Known limitation: a manually launched/resumed conversation needs a normal message for enrollment; subsequent automatic idle restores need none. Clean second-PC installation and a two-conversation restore smoke test passed for the exact published ZIP. Remaining manual acceptance scenarios are deferred.
