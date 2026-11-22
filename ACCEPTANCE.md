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

Development observations: five active-conversation restores, repeated idle restoration, and reboot passed with exact-ID/live-owner checks. Mixed deliberate-exit/plain-shell and second-PC archive acceptance remain pending.
