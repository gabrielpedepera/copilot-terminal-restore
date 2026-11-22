# Manual release acceptance

Do not publish the prerelease solely because automated tests pass.

Use the exact candidate ZIP, record its SHA-256 and tested OS/Terminal/PowerShell/Copilot versions locally, and never publish private session paths, conversations, or environment data.

1. On another Windows x64 PC/account, without source checkout, Rust, CLI wrappers, or personal dotfiles, install the ZIP into a directory containing spaces.
2. Follow README's native Terminal setup and plain-PowerShell cwd reporting. Verify ordinary tabs restore their directory.
3. Open five tabs: two enrolled Copilot conversations in the same directory; a third elsewhere; one ordinary shell; one enrolled conversation deliberately exited back to PowerShell. Submit a normal message to enroll each manually launched conversation.
4. Record exact IDs/cwd locally while keeping the three active CLIs open. Close the whole window and reopen: only those three conversations resume; the two shell tabs stay shells.
5. Repeat without new messages and verify no duplicate CLI owners.
6. Restart Windows yourself with the three CLIs running. Open Terminal normally without manual resume commands and verify the same IDs/cwd.
7. Test an initially idle, never-messaged CLI: lack of enrollment is the documented expected limitation. Test explicit-ID resume and picker resume with a normal message before closure.
8. In isolated disposable state, check missing session/directory, invalid launcher, and explicit retry; expect visible errors and a usable shell, never a silently created conversation.
9. Edit unrelated profile content, reinstall, uninstall, and verify the edit and unrelated hooks remain. Reinstall must preserve configuration/state.

Record each step passed/failed/not-run separately. Rebuild after fixes and revalidate the actual artifact; development-machine evidence does not prove clean-PC acceptance.

Development observations: five active-conversation restores, repeated idle restoration, and reboot passed with exact-ID/live-owner checks. These development results are separate from the independent candidate results below; mixed deliberate-exit/plain-shell acceptance remains pending.

## Independent candidate smoke test

The maintainer accepted the following limited evidence for an experimental prerelease, not full acceptance or a stable-release claim:

- Exact CI candidate: commit `07a84fc28aecffe00c00768256f528bd612f25ff`, Actions run `45038711757`.
- ZIP SHA-256: `eff7fe1ba0aa03f0440edd3423a3d83b00df8a7b2c7820017f41973738cf45a0`.
- Reported environment: Windows 10 x64 build 19045, Windows Terminal 1.25.3131.0, PowerShell 7.7.0 x64, native Copilot CLI 1.0.114, helper/module 0.1.0.
- Clean second-PC ZIP installation in a path containing spaces passed, with no existing helper, owned hook, or PowerShell 7 profile.
- Package-file checksums, post-install diagnostics, native launcher selection, module loading, and recognized Terminal restore settings passed.
- Two enrolled conversations resumed after whole-window closure/reopening. Saved conversation, directory, and tab identities matched; native CLI and shell owners were live. An idle CLI remained in the expected `awaitingHook` state.

| Scenario | Independent result |
|---|---|
| 1. Clean ZIP installation in a path containing spaces | Passed |
| 2. Ordinary-shell directory restoration | Not run |
| 3. Five-tab mixed setup | Not run |
| 4. Three active conversations and two shell tabs | Not run; two-conversation smoke test passed instead |
| 5. Repeated idle restoration and duplicate-owner check | Not run |
| 6. Reboot restoration | Not run |
| 7. Idle launch, explicit-ID, and picker enrollment | Not run |
| 8. Isolated failure/retry | Not run on the second PC; automated isolated checks passed separately |
| 9. Reinstall/uninstall preservation | Not run on the second PC; automated isolated checks passed separately |

Testing stopped at the maintainer's request. Remaining scenarios are deferred, not inferred from the smoke test. The packaged checklist predates this report; these repository notes and the release notes record the later results without changing the tested ZIP.
