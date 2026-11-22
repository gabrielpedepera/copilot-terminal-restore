# Agent installation runbook

Instructions for an AI coding agent (for example GitHub Copilot CLI) asked to install Copilot Terminal Restore for the current user. Humans can follow the same steps; the README remains the reference.

## Rules

- Ask the user before every step that changes their machine: downloading, installing, editing Windows Terminal settings, editing the PowerShell profile, or uninstalling. Show the exact command first.
- Never disable organization policies, change the execution policy broadly, delete Copilot session locks or transcripts, close the user's Terminal windows, or restart the PC.
- Never print, upload, or paste the contents of `%LOCALAPPDATA%\CopilotTerminalRestore\sessions`, the user's profile, or Terminal `settings.json`. Report only the specific values these steps need.
- Install only a release asset whose SHA-256 matches its `.sha256` file. Stop if it doesn't match.
- Stop and report on any unexpected failure. Don't improvise workarounds.

## 1. Check prerequisites (read-only)

```powershell
[Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$PSVersionTable.PSVersion          # 7.4 or newer
[bool]$env:WT_SESSION              # true inside Windows Terminal
(Get-Command copilot -CommandType Application -All -ErrorAction SilentlyContinue).Source
Get-Command gh -ErrorAction SilentlyContinue
```

Unsupported: Windows PowerShell 5.1, ARM64, WSL, and the npm/Node wrapper launch route. If `copilot` resolves to several paths or to a shim, tell the user and locate the native `copilot.exe`. For a first install, use `-Executable` in step 5; this does not change PATH or uninstall npm. For an existing installation, explain that `config.json` is preserved and needs a separately approved launcher edit if incorrect.

## 2. Download and verify

The repository can be private before publication, in which case `gh` must be signed in to an account with access (`gh auth status`).

```powershell
$repo = 'gabrielpedepera/copilot-terminal-restore'
$tag  = gh release list --repo $repo --limit 1 --json tagName --jq '.[0].tagName'
$dir  = Join-Path $env:TEMP "copilot-terminal-restore-$tag"
gh release download $tag --repo $repo --pattern '*-windows-x64.zip*' --dir $dir --clobber
$zip  = Get-ChildItem $dir -Filter '*-windows-x64.zip' | Select-Object -First 1
$expected = (Get-Content "$($zip.FullName).sha256" -Raw).Split(' ')[0].Trim()
if ((Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Checksum mismatch' }
Expand-Archive $zip.FullName -DestinationPath $dir -Force
$pkg = Join-Path $dir $zip.BaseName
```

## 3. Configure Windows Terminal

Ask the user to check **Settings > Startup > When Terminal starts** in Windows Terminal. If previous-session restoration is not enabled, ask them to select **Open windows from a previous session** and save.

The equivalent root-level setting in Terminal 1.25 is `"firstWindowPreference": "persistedLayoutAndContent"`. Edit `settings.json` only if the user explicitly asks, change only that key, and keep a backup.

Do not run `Test-Environment.ps1` yet: it requires the installed helper. Run it after step 5.

## 4. Choose directory reporting

Exactly one approach must report the shell's current directory:

- **Oh My Posh users:** if the active Oh My Posh config (`$env:POSH_THEME`) already contains top-level `"pwd": "osc99"`, nothing more is needed. If it uses Oh My Posh without that setting, ask the user to add it to their own config; never replace or download a theme.
- **Everyone else:** install with `-EnableDirectoryReporting`.

## 5. Install

```powershell
& "$pkg\Install.ps1"                              # Oh My Posh with pwd=osc99
& "$pkg\Install.ps1" -EnableDirectoryReporting    # plain prompt
```

If a shim shadows the native CLI, use its full path instead (combine with `-EnableDirectoryReporting` for a plain prompt):

```powershell
$native = (Get-Command copilot.exe -CommandType Application -ErrorAction Stop).Source
& "$pkg\Install.ps1" -Executable $native
```

The installer adds one personal Copilot hook and one marked block in `$PROFILE`, and backs up the profile. Reinstalling updates that block in place. Existing `config.json`, unrelated hooks and unrelated profile content are kept.

## 6. Verify and hand off

After installation, run the read-only diagnostic from the extracted package:

```powershell
& "$pkg\Test-Environment.ps1"
# If multiple Terminal settings files exist, specify the one in use:
# & "$pkg\Test-Environment.ps1" -SettingsPath 'C:\path\to\Terminal\settings.json'
```

Check that previous-session restoration is reported as `recognized`. Otherwise, resolve the reported setup issue before the restore test; for `disabled`, revisit step 3 and rerun the diagnostic after saving. Recognition alone does not prove runtime compatibility or directory reporting.

1. Ask the user to open a **new** Terminal tab. Do not assume shells or conversations started before installation are enrolled; use a fresh shell for acceptance.
2. In the new tab, `Get-Module CopilotTerminalRestore` should list the module, and the profile should load without errors from this helper.
3. Ask the user to `cd` to a project folder, start native `copilot` (`copilot.exe` if shims shadow it) and **send a normal message**. Opening a conversation without sending a message does not enroll it (known limitation).
4. Verify locally that the helper's saved record is `armed` and matches the intended conversation, cwd and live owner before closing. `Get-CtrStatus` reads this tab's record from a shell prompt; for an active CLI inspect helper records without printing their raw contents or altering Copilot files. Do not exit an active conversation just to check status: deliberate return to the prompt disarms it. If a mapping is absent, investigate rather than claiming enrollment.
5. Ask the user to close the **whole window with X** (not each tab) and reopen Terminal. The tab should resume the same conversation in the same folder. Typing `/exit` in Copilot and returning to the prompt deliberately stops restoring that tab.

Report what was installed, the package version and checksum, the directory-reporting choice, and the remaining manual steps.

## Uninstall

```powershell
& "$pkg\Uninstall.ps1"
```

This removes only the owned hook and profile block and keeps the user's other profile edits. State and binaries under `%LOCALAPPDATA%\CopilotTerminalRestore` are left in place for deliberate cleanup.
