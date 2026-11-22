# Copilot Terminal Restore

Experimental Windows x64 helper that resumes enrolled Copilot CLI conversations inside ordinary restored Windows Terminal tabs. No multiplexer, replacement terminal, or background service.

**Experimental prerelease, not a stable release.** [Download the Windows x64 ZIP and checksum](https://github.com/gabrielpedepera/copilot-terminal-restore/releases/tag/v0.1.0), then follow the installation steps below. The unsigned package needs no Rust toolchain. Independent acceptance is still pending; if no release is listed, a candidate is not yet available to install.

Windows Terminal restores the tabs; a Rust helper maps terminal identity to conversation identity; a small PowerShell module resumes the exact conversation and observes deliberate return to the shell.

## Supported scope

- Windows x64, PowerShell 7.4 or newer, native `copilot.exe`.
- Windows Terminal with previous-session restoration enabled.
- One Copilot conversation per tab.
- Plain `copilot` is the default launcher. No CLI wrapper, aliases, font, theme engine, or developer toolchain is required to install a release ZIP.

Locally exercised with Windows Terminal 1.25.3131.0, PowerShell 7.6.10, and Copilot CLI 1.0.114. Auth-free shell/installer checks also passed on PowerShell 7.4.22; 7.4 is the API minimum, not a claim that every earlier patch was tested. Five enrolled conversations, repeated idle restoration, and a real reboot preserved their exact IDs in the development environment. Independent release-package acceptance is still pending.

**Enrollment limitation:** submit one normal message after manually opening or resuming a conversation. Running only `/session id` may not fire the start hook and does not enroll it. This includes valuable existing conversations resumed through the picker, not only empty sessions. Once enrolled, automatic restores require no new message.

Sidebar multi-conversation switching, `/new`, WSL, ARM64, npm/Node-hosted CLI, and remote sessions are not supported in this first release.

## 1. Configure Windows Terminal

Open **Settings > Startup > When Terminal starts > Open windows from a previous session** and save.

The root-level settings value tested with Terminal 1.25 is:

```json
"firstWindowPreference": "persistedLayoutAndContent"
```

Older Terminal versions may expose `persistedWindowLayout`. Use the option supported by your installed version; diagnostics recognize both but cannot guarantee runtime compatibility.

`startupActions` opens a fixed layout. It is not a snapshot of the tabs you currently have open; do not use it as a substitute for previous-session restoration. The helper does not modify either setting.

Test by closing the **whole window using X**, not each tab individually, and reopening Terminal. Multi-window behavior is not part of the verified support matrix. “Launch on machine startup” is optional; you can open Terminal yourself after signing in.

## 2. Install the ZIP

Obtain the experimental Windows x64 ZIP and its `.sha256` from this project's Releases, or with the GitHub CLI:

```powershell
gh release download v0.1.0 --repo gabrielpedepera/copilot-terminal-restore --pattern '*-windows-x64.zip*'
```

The explicit tag also selects a prerelease. Private repositories require an authenticated account with access. To have an AI agent such as Copilot CLI install it for you, point it to [docs/AGENT-INSTALL.md](docs/AGENT-INSTALL.md), also included in the ZIP.

Check the downloaded checksum:

```powershell
$zip = '.\copilot-terminal-restore-v0.1.0-windows-x64.zip'
$expected = (Get-Content "$zip.sha256" -Raw).Split(' ')[0].Trim()
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Checksum mismatch; do not install'
}
```

Extract the ZIP, open PowerShell in the extracted directory, and run:

```powershell
.\Install.ps1
```

This creates one owned personal Copilot hook and appends one marked block to the current user's PowerShell host profile. It preserves unrelated profile content, hooks, and existing launcher configuration, and creates a profile backup. Reinstalling updates the block where it already is.

If `Get-Command copilot -All` shows npm shims or another wrapper ahead of the native Windows executable, select the native launcher during the first install:

```powershell
$native = (Get-Command copilot.exe -CommandType Application -ErrorAction Stop).Source
.\Install.ps1 -Executable $native
```

Use `copilot.exe` for manual launches in that setup. This does not change PATH or uninstall npm; the wrapper route is outside the verified support scope. Reinstalls preserve existing launcher configuration, so inspect `config.json` if already installed. Add `-EnableDirectoryReporting` for a plain prompt as described below.

Do not disable organization policies or broadly change execution policy to install this helper. The binary/scripts are unsigned; review the source and follow your environment's approved way to run downloaded software.

Use a fresh PowerShell tab afterward. In an existing real PowerShell prompt you can run `. $PROFILE`. Do not assume an already-running Copilot process is enrolled; use the fresh-tab procedure and verify its saved mapping before testing.

For a source checkout, first `cargo build --release --locked`, then `.\scripts\Install.ps1`. Release recipients do not need Cargo.

## 3. Enable shell directory reporting

Reporting cwd is separate from tab restoration and conversation resumption. Windows Terminal needs shell reporting to restore the last directory of ordinary shell tabs; the helper also records the enrolled conversation's cwd.

For a plain PowerShell prompt, install (or reinstall) with the directory-reporting option:

```powershell
.\Install.ps1 -EnableDirectoryReporting
```

This adds `Enable-CtrDirectoryReporting` inside the owned profile block, where the module is already loaded; later reinstalls keep the choice. The block must stay **after your existing prompt initialization** in `$PROFILE`, which is where a first install appends it. Then load `. $PROFILE` at a PowerShell prompt or open a fresh tab. The function wraps the existing prompt rather than replacing its appearance and reports filesystem locations via OSC 9;9.

If you already use Oh My Posh, instead enable its top-level setting in your own theme/config:

```json
"pwd": "osc99"
```

Use one reporting approach. The installer never edits themes or installs Oh My Posh. Test by changing to a directory, closing the whole window, and reopening.

## 4. Enroll and verify

After installing and configuring directory reporting, run the diagnostic from the extracted package:

```powershell
.\Test-Environment.ps1
```

This is a **post-install** check: it requires the installed helper and must not be run before `Install.ps1`. Check that Terminal restoration is reported as `recognized`; if it is `disabled`, revisit step 1, save the setting, and rerun the check. See **Configuration and diagnostics** below for other reported statuses and selecting a settings file. Recognition does not replace the whole-window restore test.

Open a fresh PowerShell tab and check that `Get-Module CopilotTerminalRestore` lists the module without helper startup errors. Launch native `copilot` (or `copilot.exe` when shims shadow it), send a normal message, and keep it running. The personal hook records the exact conversation ID plus cwd and process ownership. A delayed or absent mapping is not proof of enrollment; investigate it before closing the window.

Close/reopen the whole Terminal window. Copilot should resume the same conversation automatically. It does not submit a new message or replay an interrupted tool.

Before a larger test, verify that the saved record is `armed` and maps to the intended conversation, cwd, and live owner. `Get-CtrStatus` reads this tab's record from its PowerShell prompt; active tabs can be checked by reading helper records locally, without modifying Copilot's locks/transcripts. Do not exit an active conversation merely to collect status immediately before testing; deliberate shell return disarms it. Do not post raw records or real IDs/paths publicly.

If you deliberately `/exit` Copilot and leave PowerShell open, the next prompt disarms restoration for that tab. Agent turn completion does not count as CLI exit.

## Configuration and diagnostics

`%LOCALAPPDATA%\CopilotTerminalRestore\config.json`:

```json
{
  "executable": "copilot",
  "args": []
}
```

`executable` is an application name or full executable path, not an alias/shell expression. One match is selected in PATH order; set a full native CLI path if a shim shadows it. The helper appends `--resume` and the exact saved ID as separate arguments. Do not put prompt/session overrides into `args`.

Reinstallation preserves this file. One installation serves one Copilot home: the installer uses `COPILOT_HOME` (or `-CopilotHome`) at install time, and sessions started with a different `COPILOT_HOME` are not enrolled. To switch homes, uninstall and reinstall. Disabled hooks or incompatible CLI builds cannot enroll sessions.

After installation, from the extracted package:

```powershell
.\Test-Environment.ps1
.\Test-Environment.ps1 -SettingsPath 'C:\path\to\Terminal\settings.json'
```

The check reports missing, malformed, disabled, recognized, or unverified restore settings; if multiple Terminal variants are installed, specify the actual settings file. It does not print unrelated settings or prove cwd reporting from `WT_SESSION` alone.

In a registered PowerShell tab:

```powershell
Get-CtrStatus
Resume-CtrSession
Disable-CtrSession
```

Retry is explicit after failure; no replacement conversation is silently created. Set `$env:CTR_DISABLE = '1'` before loading the profile to bypass the helper. `pwsh -NoProfile` provides a recovery shell.

User state lives under `%LOCALAPPDATA%\CopilotTerminalRestore\sessions`, separate from Copilot's own files. It contains local paths, IDs, and process metadata: do not attach raw records/logs publicly. Never delete Copilot's session locks as a recovery shortcut.

## Uninstall

From the extracted package:

```powershell
.\Uninstall.ps1
```

Removes only the owned profile block and unchanged owned hook. Existing profile edits are retained, including edits made before a reinstall; the original profile is restored from backup (or an installer-created profile deleted) only when nothing else changed. An edited owned hook is reported instead of deleted. Binaries, backups, configuration, and recovery records remain for deliberate cleanup. Restart old shells to unload already-running integration.

## Development and validation

Rust 1.100+, MSVC build tools, and PowerShell 7.4+:

```powershell
cargo test --locked
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo build --release --locked
.\tests\Invoke-InstallationTests.ps1
.\tests\Invoke-ShellAdapterTests.ps1
.\tests\Invoke-TerminalSetupTests.ps1
.\tests\Invoke-DirectoryReportingTests.ps1
$package = .\scripts\Build-Package.ps1
.\tests\Invoke-PackageTests.ps1 -Archive $package.archive
```

Packaging uses an explicit file list and generates full third-party source license notices from Cargo.lock. `target`, `test-results`, and `dist` are not public source files.

Interactive lifecycle probes are **opt-in**: they require your own authenticated Copilot, submit a small no-tools message, and create conversations under your Copilot home. CI runs auth-free synthetic/native tests, not those live probes.

See `ACCEPTANCE.md` for manual real-Terminal/reboot/package checks, `CONTRIBUTING.md` for contribution guidelines, and `STATE.md` for recovery-state semantics.

## Known limitations

- Initial idle manual launches may not enroll until a normal message, including manually resumed older conversations.
- Observable multiple conversations in one live CLI disable automatic selection. Silent sidebar switches without lifecycle signals cannot be detected reliably.
- Exact-ID resume preserves history; it is not a guarantee to continue an interrupted task/tool.
- Command-line ownership inspection uses a Windows NT API and is tested only on the advertised Windows scope.
- Atomic replacement and flushing reduce state corruption risk, not arbitrary storage failure.
- Repository hooks/policies and conflicting profile initialization may affect behavior; do not claim success without pre-close enrollment.
- Terminal-Icons 0.11.0 may race when several shells import its shared XML cache. This is a third-party profile issue; this product does not ship or change that module.

This is an independent experimental project, not an official GitHub or Microsoft product.
