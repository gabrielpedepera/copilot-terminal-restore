# Contributing

Keep the first release focused on Windows x64, PowerShell 7, and native Copilot CLI in ordinary Terminal tabs.

Run the README validation commands. CI tests must not require authenticated Copilot, CLI wrappers, MCP servers, personal profiles, or a theme engine. Real CLI/GUI/reboot acceptance is opt-in and must be recorded separately.

Add a focused regression for changed behavior. Preserve exact session-ID mapping, owner creation-time checks, atomic per-tab state, deliberate-exit behavior, and separate executable/argument handling. Never parse terminal text or guess a conversation from its directory/title.

Do not include runtime state, logs, profile backups, secrets, or real conversation IDs in commits/issues. Use synthetic fixtures. Package only allowlisted release files.

Use GitHub Issues for bugs once the repository is available; include redacted versions, expected/actual behavior, and reproduction steps. If private vulnerability reporting is enabled, use it for sensitive reports. Do not post credentials or exploitable sensitive details publicly; reporting availability must be configured before publication.
