# Local state contract, schema version 1

One record per normalized `WT_SESSION` GUID under the helper's `sessions` directory. This Terminal connection identifier is distinct from the Copilot conversation GUID. Records store cwd, Copilot home, CLI/shell PID plus creation timestamp, generation, state, attempts, and diagnostic message. They contain metadata, not conversation content.

Per-tab exclusive locks serialize operations. Writes flush a temporary file and replace the record using Windows replacement semantics. Readers reject malformed, oversized, unknown-version, or invalid-ID/path records rather than launching.

- `armed`: an eligible start hook mapped the native interactive CLI.
- `endObserved`: end hook observed; not proof of deliberate exit, since Terminal closure may also report user_exit.
- `restoring`: new shell claimed exact-ID restoration; concurrent live claims suppress another launch.
- `awaitingHook`: the resume launcher is registered as a temporary owner because the CLI may defer start hooks. Hook ownership can then move to the actual native CLI.
- `dormant`: deliberate return to shell/disarming; do not auto-resume.
- `ambiguous`: observable multiple conversations in one owner; no arbitrary session selection.
- `failed`: visible error or bounded retry exhaustion; requires explicit recovery.

Late generations and old shell notifications cannot take over/disarm current owners. PID alone is insufficient because Windows can reuse it.

Release upgrades preserve configuration and state. Schema 1 is currently the only accepted version; a future schema requires explicit migration/tests or a reported unsupported-version error. Do not clear/mutate Copilot's own locks/transcripts.
