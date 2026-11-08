# Reprise

Reprise has native Mac menubar and Windows system-tray apps. It automatically collects local Codex, Claude, and Grok Build sessions, and turns terminal screenshots into an organized library of AI coding-session resume commands.

On Mac, drop a screenshot on the Reprise status icon. On Windows, add it through the tray menu or drop it into the library window. Local OCR detects commands such as:

```sh
codex resume session-id
claude --resume session-id
grok --resume session-id
```

The app lets you review the detected assistant and command, add or detect the project directory, attach a project name and note, then copy the command later from a grouped local library. Screenshots are processed on-device and are never uploaded. Mac uses Apple Vision; Windows bundles Tesseract and an English OCR model.

## Windows download

Download **Reprise-win-Setup.exe** from the [latest release](https://github.com/en-code23/reprise/releases/latest). The x64 installer bundles the .NET runtime, OCR engine, English model, and app-local Visual C++ runtime files. A portable ZIP is also available. Windows builds are currently unsigned.

The Windows app lives in the notification area/system tray. Click its icon to open the library; closing the window keeps it running. Use its tray menu to add a screenshot, or drop a PNG, JPG, BMP, or TIFF into the library/capture window. Windows does not support dropping files directly onto this tray icon. Review OCR results before saving, or enter a command manually.

Windows groups sessions by Windows project directory, with Projects, Unassigned, and Internal views, assistant/source filters, notes, and history. It reads native Windows Codex, Claude, and Grok session metadata from your user profile, respecting `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `GROK_HOME`. Linux/WSL transcript folders and cloud-only chat histories are not automatically imported.

Choose **Windows Terminal**, **PowerShell**, or **Command Prompt** as the default terminal. The relevant Windows CLI must be installed, on PATH, and signed in. Opening an editor accepts an editor `.exe`, opens the project folder, and copies the selected command. Installer builds support **Check for updates** through Velopack; portable copies are replaced manually. Windows updates use GitHub release packages and their checksums; the separate Mac feed uses Sparkle/Ed25519 signatures.

Windows sessions and preferences live in `%LOCALAPPDATA%\RepriseLibrary`, outside the install directory. Closing or updating the app preserves them; the original CLI session files are never modified.

Build on Windows with .NET 10 and the Visual Studio C++ redistributable files available:

```powershell
./scripts/build-windows.ps1 -Version 1.6.0
```

The script runs core checks, publishes a self-contained app, verifies its UI/OCR on Windows, and builds the installer and update packages with pinned Velopack tooling. `-TestInstaller` additionally installs and tests the package on a clean CI runner. Windows previews are saved under `build/windows/qa/`. Run the portable core checks on any .NET 10 host with `dotnet run --project windows/Reprise.Core.Tests -c Release`.

The remaining sections describe the Mac app unless stated otherwise.

## Resume your work

The library opens when Reprise starts. Select a session to see the full command, folder, and notes. Choose **Default terminal** in the library sidebar or menubar menu: Apple Terminal, Ghostty, or iTerm2. The choice is saved and the Resume button shows the selected app. It opens a new window, changes to the project directory, and starts the appropriate CLI. Choose a new folder if the project has moved. The installed CLI must be available in your shell and signed in.

Reprise keeps one running instance per macOS user, including when you open a second app copy from a build folder or disk image. Opening it again brings the existing library forward. Quit older releases before replacing the app during an update.

The library shows one row per project directory, with sessions from different assistants together. Selecting a project chooses its latest session; use its history to resume an earlier conversation. Project names alone are never used for grouping, so two folders with the same name stay separate.

### Desktop app versus CLI

Each session shows its recorded source: **Desktop app**, **CLI**, **IDE extension**, **SDK / automation**, **Multiple clients**, or **Unknown**. Combine an assistant filter with the **All sources** menu to show, for example, Codex desktop sessions or Claude CLI sessions without splitting the project library into duplicate rows.

Codex detection uses specific `originator` markers, preferring them over the broad `source` value (Desktop can also report `vscode`). Claude detection uses top-level `entrypoint` metadata such as `cli`, `claude-desktop`, `sdk-cli`, and `sdk-py`. Multiple recognised entrypoints in the scanned portion are labelled Multiple clients. Discovery still reads only the first 256 KB of a file; it cannot reliably identify every client used throughout the whole conversation.

Records without enough evidence stay Unknown. Use **Session details → Session source** to correct a label or select Automatic to return to metadata detection. The same selector is available during screenshot/manual capture review. On the next sync, old records gain metadata labels without losing your edits or overrides.

These are recorded origins for **local coding sessions**, not a live connection indicator. Regular cloud-only Claude chats are not discovered. The source label does not change how Resume works: it still uses your chosen terminal and the saved resume command.

Older screenshot/manual entries without a folder are preserved under **Unassigned**. Assign a directory to move them into Projects. Sessions inside `.codex`, `.claude`, `.chatgpt`, or `.grok` directories are available under **Internal**, apart from regular projects. No conversations or captures are deleted by this organisation change.

macOS may ask to allow Reprise to control your selected terminal on first use. Permission can be managed in System Settings → Privacy & Security → Automation. Ghostty requires version 1.3 or newer with AppleScript enabled (`macos-applescript = true`, the default). Reprise uses Ghostty's native window configuration with a project directory and initial command input, preserving your configured shell. See [Ghostty's scripting documentation](https://ghostty.org/docs/features/applescript). Reprise validates commands and quotes directory paths before launching; arbitrary shell scripts are not supported. Custom commands remain copyable.

## Open in your editor

Choose **Default editor** in the library sidebar. Installed editors appear in the menu; use **Choose another editor…** to select any other editor application. The choice is saved. Click **Open in VS Code** (or your selected editor) to open the session's project folder and copy its resume command. Paste it into the editor's terminal to continue that conversation. Reprise opens the folder through macOS, so an editor command-line launcher is not required. It copies the command only after the project opens successfully; it does not run it or change editor configuration.

## In-app updates

Use **Check for updates** at the bottom of the library or in the menubar options. Sparkle shows available updates and downloads, verifies, installs, and relaunches them inside Reprise. Checks are initiated by you. Both the feed and archives are signed with Ed25519; the public key is embedded in the app. Install v1.5.0 once using the DMG to gain this feature in older versions.

Update checks contact GitHub. Saved sessions, commands, screenshots, and project notes are not sent with them.

The release workflow requires the repository secret `SPARKLE_PRIVATE_KEY`. Keep a private backup of the signing seed outside this repository. `scripts/make-appcast.sh` signs the ZIP and feed, verifies the signed feed, and checks the ZIP signature against the public key embedded in the packaged app. It publishes `appcast.xml` with each release; the app reads the latest release's feed. Locally, set `SPARKLE_PRIVATE_KEY_FILE` to a private key file when running the script. Never commit the seed. Sparkle setup follows its [official documentation](https://sparkle-project.org/documentation/).

## Automatic local discovery

While Reprise is running, it scans `~/.codex/sessions`, `~/.claude/projects`, and `~/.grok/sessions` at startup and every 30 seconds. `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `GROK_HOME` are respected when present in the app's environment. Use **Sync now** for an immediate refresh, or turn off **Auto-save local sessions** at the bottom of the library.

Only session ID, assistant, project directory, activity time, and source metadata are retained. Conversation messages and tool output are not imported. Reading is limited to the first 256 KB of Codex/Claude transcripts. For Grok Build, only `summary.json` is read, with a 1 MB limit; its `info.id` and `info.cwd` fields are authoritative, and its saved activity timestamps take precedence over the file modification time. Grok transcripts, prompts, generated titles, and conversation summaries are not imported. Unsupported or incomplete files are skipped and may be found on a later scan. Nested subagent folders and symbolic-link summaries are excluded.

Grok Build's summary format is shared by TUI, headless, and ACP clients and does not reliably identify the originating client. Imported Grok sources therefore stay Unknown unless set manually. This integration supports the installed Grok Build format, not arbitrary third-party Grok clients or cloud chat histories. See [Grok Build's session format](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/17-sessions.md).

Repeated scans do not duplicate sessions or replace your edited project name, directory, or notes. Removing a session from Reprise leaves the original CLI conversation intact and suppresses automatic re-import. Local storage lives in `~/Library/Application Support/Reprise/sessions.json`.

Claude and Grok Build require `--resume`, while Codex uses the `resume` subcommand. Older saved commands are updated accordingly when loaded.

## Requirements

- macOS 14 or newer
- Apple silicon or Intel Mac
- Xcode 16 or newer / Swift 6

## Build the native app

```sh
swift build --package-path macos
```

Create a signed-on-disk app bundle, ZIP, and DMG:

```sh
./scripts/build-release.sh
```

Artifacts are written to `dist/`.

Run native parser, discovery, persistence, and terminal-launch validation with `swift test --package-path macos`. To render light/dark UI fixtures, set `REPRISE_RENDER_DIR` to an output directory when running the tests.

## Download site

The static GitHub Pages site lives in `docs/`. It looks up the latest GitHub Release and provides separate Mac DMG and Windows EXE downloads. The main download button follows the visitor's platform.

## Releases

Push a version tag to build and publish a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The initial workflow uses an ad-hoc signature. For a frictionless public download, configure an Apple Developer ID certificate and notarization credentials in the release workflow.

## Prototype

The original browser prototype remains in `src/` as a design reference. The shipping apps are the native Swift app under `macos/` and native WinForms app under `windows/`.

## License

MIT
