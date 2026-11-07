# Reprise

Reprise is a native macOS menubar app that automatically collects local Codex and Claude sessions, and turns terminal screenshots into an organized library of AI coding-session resume commands.

Drop a screenshot on the Reprise status icon. Apple Vision OCR detects commands such as:

```sh
codex resume session-id
claude --resume session-id
grok resume session-id
```

The app lets you review the detected assistant and command, add or detect the project directory, attach a project name and note, then copy the command later from a grouped local library. Screenshots are processed on-device and are never uploaded.

## Resume your work

The library opens when Reprise starts. Select a session to see the full command, folder, and notes. **Resume in Terminal** opens a new Apple Terminal session, changes to the project directory, and starts the appropriate CLI. Choose a new folder if the project has moved. The installed CLI must be available in your shell and signed in.

macOS may ask to allow Reprise to control Terminal on first use. Permission can be managed in System Settings → Privacy & Security → Automation. Reprise validates commands and quotes directory paths before launching; arbitrary shell scripts are not supported. Custom commands remain copyable.

## Automatic local discovery

While Reprise is running, it scans `~/.codex/sessions` and `~/.claude/projects` at startup and every 30 seconds. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are respected when present in the app's environment. Use **Sync now** for an immediate refresh, or turn off **Auto-save local sessions** at the bottom of the library.

Only session ID, assistant, project directory, and file modification time are retained. Conversation messages and tool output are not imported. Reading is limited to the first 256 KB of each transcript. Unsupported or incomplete files are skipped and may be found on a later scan. Subagent folders are excluded.

Repeated scans do not duplicate sessions or replace your edited project name, directory, or notes. Removing a session from Reprise leaves the original CLI conversation intact and suppresses automatic re-import. Local storage lives in `~/Library/Application Support/Reprise/sessions.json`.

Claude's installed CLI requires `--resume`, while Codex uses the `resume` subcommand. Older saved commands are updated accordingly when loaded.

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

The static GitHub Pages site lives in `docs/`. It looks up the latest GitHub Release and points the download button at its DMG automatically.

## Releases

Push a version tag to build and publish a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The initial workflow uses an ad-hoc signature. For a frictionless public download, configure an Apple Developer ID certificate and notarization credentials in the release workflow.

## Prototype

The original browser prototype remains in `src/` as a design reference. The shipping product is the native Swift app under `macos/`.

## License

MIT
