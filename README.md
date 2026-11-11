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

Build on Windows with .NET 10, stable Rust, Python 3, and the Visual Studio C++ redistributable files available:

```powershell
./scripts/build-windows.ps1 -Version 1.9.0
```

The script runs core checks, publishes a self-contained app, verifies its UI/OCR on Windows, and builds the installer and update packages with pinned Velopack tooling. `-TestInstaller` additionally installs and tests the package on a clean CI runner. Windows previews are saved under `build/windows/qa/`. Run the portable core checks on any .NET 10 host with `dotnet run --project windows/Reprise.Core.Tests -c Release`.

## Session names on Mac and Windows

Select a project, then choose a session by name. On Mac, use the selected session’s **… → Rename session** menu or right-click its history row. On Windows, use **… → Rename / edit session** or double-click the row. A Session name field is also available when adding a screenshot or entering a command.

Saved names are imported from Codex's `session_index.jsonl`, Claude's `custom-title` and `ai-title` records, and Grok's `generated_title` metadata. You can give any session your own name in Reprise. Your name survives sync and restart; clear the field to use the latest imported name again. Entries without a name show a short session-ID fallback. Names identify conversations in project history; the library search matches only the project's folder name. Renaming leaves project grouping and resume commands intact. Reprise does not write names back to the original CLI files.

The Codex index read is limited to its most recent 8 MB. Claude discovery additionally reads up to 256 KB from the end of a transcript, retaining only directory, source, session ID, and title metadata. This also recovers older files with large queued-input headers. Custom titles take precedence over generated titles. Names outside these bounds may need to be entered manually. Names are normalized to one line and limited to 200 characters.

The remaining sections describe the Mac app unless stated otherwise.

## Resume your work

The library opens when Reprise starts. Choose a folder on the left and a conversation on the right. Resume, copy, or open in your editor from the project header. Expand **Session details** for the command and notes. Choose **Default terminal** in **Reprise → Settings** (⌘,) or the menubar menu: Apple Terminal, Ghostty, or iTerm2. The choice is saved and the Resume button shows the selected app. It opens a new window, changes to the project directory, and starts the appropriate CLI. Choose a new folder if the project has moved. The installed CLI must be available in your shell and signed in.

Reprise appears in both the Mac Dock and menu bar. Clicking its Dock icon opens the library, including when the window is closed or minimized. Closing the library keeps Reprise and automatic discovery running; use Reprise → Quit Reprise or the menu bar's Quit action to exit.

Reprise keeps one running instance per macOS user, including when you open a second app copy from a build folder or disk image. Opening it again brings the existing library forward. Quit older releases before replacing the app during an update.

The library shows one row per project directory, with sessions from different assistants together. Selecting a project chooses its latest session; use its history to resume an earlier conversation. Project names alone are never used for grouping, so two folders with the same name stay separate.

Search matches only the folder's final name, ignoring case and surrounding spaces. Commands, notes, session names, source labels, and parent paths do not affect the results. All sessions for a matching folder remain together.

When local discovery finds a session previously saved from a screenshot without a folder, it fills the missing directory and moves the entry into its project. The same entry ID, session name, and notes are preserved. Placeholder screenshot labels are replaced with the folder name; explicitly chosen folders and project labels stay intact.

### Desktop app versus CLI

Each session shows its recorded source: **Desktop app**, **CLI**, **IDE extension**, **SDK / automation**, **Multiple clients**, or **Unknown**. The default **Main sessions** source filter hides SDK/automation entries. Choose **All sources** to include automation, or **SDK / automation** to view it separately. Open **Filter** to combine a source with an assistant to show Codex desktop sessions or Claude CLI sessions without splitting projects into duplicate rows.

Confirmed subagents are excluded from the library and menu bar recents, including Codex subagent metadata, Claude sidechain conversations, legacy `agent-` files, and nested subagent folders. Previously imported records recognized as subagents remain stored with their notes and names; they are filtered out rather than deleted. A primary transcript takes precedence if the same session ID also appears in a child record.

Codex detection uses specific `originator` markers, preferring them over the broad `source` value (Desktop can also report `vscode`). Claude detection uses top-level `entrypoint` metadata such as `cli`, `claude-desktop`, `sdk-cli`, and `sdk-py`. Multiple recognised entrypoints in the scanned portion are labelled Multiple clients. Source detection uses bounded header/tail metadata or the local Codex index; it cannot reliably identify every client used throughout the whole conversation.

Records without enough evidence stay Unknown. Use **… → Edit details → Session source** to correct a label or select Automatic to return to metadata detection. The same selector is available during screenshot/manual capture review. On the next sync, old records gain metadata labels without losing your edits or overrides.

These are recorded origins for **local coding sessions**, not a live connection indicator. Regular cloud-only Claude chats are not discovered. The source label does not change how Resume works: it still uses your chosen terminal and the saved resume command.

Older screenshot/manual entries without a folder are preserved under **Unassigned**. Assign a directory to move them into Projects. Sessions inside `.codex`, `.claude`, `.chatgpt`, or `.grok` directories are available under **Internal**, apart from regular projects. No conversations or captures are deleted by this organisation change.

macOS may ask to allow Reprise to control your selected terminal on first use. Permission can be managed in System Settings → Privacy & Security → Automation. Ghostty requires version 1.3 or newer with AppleScript enabled (`macos-applescript = true`, the default). Reprise uses Ghostty's native window configuration with a project directory and initial command input, preserving your configured shell. See [Ghostty's scripting documentation](https://ghostty.org/docs/features/applescript). Reprise validates commands and quotes directory paths before launching; arbitrary shell scripts are not supported. Custom commands remain copyable.

## Open in your editor

Choose **Default editor** in **Settings**. Installed editors appear in the menu; use **Choose another editor…** to select any other editor application. The choice is saved. Click **Open in VS Code** (or your selected editor) to open the session's project folder and copy its resume command. Paste it into the editor's terminal to continue that conversation. Reprise opens the folder through macOS, so an editor command-line launcher is not required. It copies the command only after the project opens successfully; it does not run it or change editor configuration.

## Optional automatic model selection

In **Settings → Model selection**, enable automatic selection and open **Usage and model settings**. On Windows, use **Settings → Automatic model selection**. The feature is off until you enable it. It chooses within the conversation’s existing provider, preserving its session ID. It cannot transfer a Claude conversation to Codex or Grok.

With **Switch between turns in managed sessions** enabled, Resume opens the bundled Reprise runner in your chosen terminal, including Ghostty. Each new task is assessed before it is sent. Codex uses its app-server protocol, Claude uses its stream-JSON session controls, and Grok Build uses ACP. Changes happen between completed turns. Already-running native app and CLI interfaces are not remotely controlled. Turn this option off to choose a model at launch and retain the provider’s usual terminal interface. If the provider rejects a setting, the prompt is not sent with a silently substituted model.

The runner provides text streaming, tool activity, explicit permission requests, cancellation with Ctrl+C, and these commands:

| Command | Action |
| --- | --- |
| `/usage` | Show the latest quota windows and resets |
| `/work ui`, `backend`, `foundation`, `small`, or `auto` | Set or clear a work-type hint |
| `/model <id> [effort]` | Explicitly choose an advertised model and effort |
| `/auto off` / `/auto on` | Pause automatic changes or return to automatic selection |
| `/quit` | Close the managed session; keep the original conversation history |

Provider-specific native TUI commands, image attachments, and interactive extensions are not reproduced by the text runner. Use launch-only selection or **Copy original CLI command** for the provider’s full native interface. Managed Copy command and Open in editor copy the runner command; on Windows paste it into PowerShell. The original saved resume command is retained in Session details.

Selection uses a bounded local scan of filenames, folder structure, modification times, test coverage by file count, manifest count, and capped Git commit count. It also considers task wording between turns, or your chosen work type. Source file contents are not sent to a separate classification model. This is a heuristic estimate of task suitability, not a guarantee of a perfect choice or exact token cost. Model roles can be adjusted in settings as providers change their catalogs. Normal choices stop at high effort. The optional max exception requires a large, early backend foundation task and at least 75% shared quota remaining; reset timing alone never enables max. Ultra is never selected automatically.

Usage pacing considers every applicable shared and model-specific window. Low headroom or a long wait until reset reduces capability; a near reset can increase capability only if the other shared windows also have room. An elapsed reset time does not locally refill a cached quota. Unknown or stale usage uses a conservative verified model, excluding Fable and reset boosts; a freshly exhausted shared limit blocks automatic turns. Actual usage and billing remain governed by each provider’s account settings and enforcement.

Codex reads its account’s advertised model catalog, supported efforts, and rate-limit windows. **Connect Claude usage** explicitly enables reading Claude Code’s existing subscription login; macOS may ask for Keychain access. Credentials stay in memory during the provider request and are never placed in Reprise’s settings, usage cache, command descriptor, or clipboard. Reprise does not refresh or modify those credentials. Claude’s usage endpoint can change independently of this app.

Fable is additionally opt-in. Reprise needs fresh shared weekly headroom and a fresh separate Fable allowance. Named Fable fields are detected automatically. If Claude returns an unnamed allowance field, manually match it to Fable in Claude’s Usage screen before selecting that field and refreshing. Reprise never guesses an internal field’s meaning and never redeems reset credits. When the mapping or allowance is unknown, it uses another model. See [Claude’s Fable allowance guidance](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan).

Grok Build currently does not expose plan quota percentages through `grok usage --json` on every account. Its ACP model and effort capabilities are supported, but missing usage stays Unknown and cannot trigger reset boosts. Token counts and API costs are not treated as subscription quota. Grok must be signed in and support loading sessions through ACP.

Preferences are stored in `model-routing.json` alongside the library; metadata-only runner caches are under `routing-usage`. Original session data and per-project exclusions are preserved. The runner uses each provider’s existing approval and sandbox settings and asks before granting requested tool permissions. It does not enable bypass modes.

The managed runner builds with `cargo build --locked --manifest-path runner/Cargo.toml`; run its protocol and policy tests with `cargo test --locked --manifest-path runner/Cargo.toml`. Mac release builds also need the `aarch64-apple-darwin` and `x86_64-apple-darwin` Rust targets. Packaged releases include the runner and dependency notices; users do not need Rust installed.

## In-app updates

Use **Settings → Check for updates** or the menubar options. Sparkle shows available updates and downloads, verifies, installs, and relaunches them inside Reprise. Checks are initiated by you. Both the feed and archives are signed with Ed25519; the public key is embedded in the app. Install v1.5.0 once using the DMG to gain this feature in older versions.

Update checks contact GitHub. Saved sessions, commands, screenshots, and project notes are not sent with them.

The release workflow requires the repository secret `SPARKLE_PRIVATE_KEY`. Keep a private backup of the signing seed outside this repository. `scripts/make-appcast.sh` signs the ZIP and feed, verifies the signed feed, and checks the ZIP signature against the public key embedded in the packaged app. It publishes `appcast.xml` with each release; the app reads the latest release's feed. Locally, set `SPARKLE_PRIVATE_KEY_FILE` to a private key file when running the script. Never commit the seed. Sparkle setup follows its [official documentation](https://sparkle-project.org/documentation/).

## Automatic local discovery

While Reprise is running, it scans `~/.codex/sessions`, `~/.codex/archived_sessions`, `~/.claude/projects`, and `~/.grok/sessions` at startup and every 30 seconds. `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `GROK_HOME` are respected when present in the app's environment. Use **Sync now** for an immediate refresh, or turn off automatic discovery in **Settings**.

Older Codex conversations are also found in the newest local `state_N.sqlite` history index, opened read-only and limited to 5,000 metadata rows. Reprise checks whether each referenced transcript exists. Missing transcripts remain visible as **History not local** references with Resume disabled. Reprise cannot reconstruct missing conversation files; open the conversation in Codex if available, then sync again.

Only session ID, name, assistant, project directory, activity time, source metadata, and local-history availability are retained. Conversation messages and tool output are not imported. Header reading is limited to the first 256 KB of Codex/Claude transcripts; the additional name metadata reads are bounded as described above. For Grok Build, only `summary.json` is read, with a 1 MB limit; its `info.id` and `info.cwd` fields are authoritative, and its saved activity timestamps take precedence over the file modification time. Grok's generated title is retained as the session name; transcripts, prompts, and conversation summaries are not imported. Unsupported or incomplete files are skipped and may be found on a later scan. Nested subagent folders and symbolic-link summaries are excluded.

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
