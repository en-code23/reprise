# Release notes

## 1.6.1

- Show the Mac app in the Dock and app switcher as well as the menu bar. Clicking its Dock icon opens the library and restores a minimized library window.
- Keep Reprise and automatic session discovery running when the library window closes; quit through the app or menu bar menu.
- Remove the empty Settings window from startup and reopening. Keep standard Mac application, editing, and window menus.

## 1.6.0

- Add a native Windows x64 system-tray app, a self-contained EXE installer, portable ZIP, and Velopack update packages alongside the existing Mac release.
- Discover local Windows Codex, Claude, and Grok Build session metadata, group by Windows project directory, distinguish sources, preserve edited notes, and keep Unassigned/Internal views separate.
- Import screenshots using bundled offline Tesseract/English OCR, with editable review and manual command entry. Screenshots can be dropped into the library/capture window or chosen from the tray menu.
- Resume in Windows Terminal, PowerShell, or Command Prompt with validated command arguments and literal project paths. Open an editor executable and copy the selected resume command.
- Keep Windows data outside the installation directory, prevent duplicate app instances, preserve unreadable libraries, and support restoring removed imports.
- Build/test both platforms before publishing one release; verify Windows UI, OCR, command quoting, and installer startup on a Windows runner. Add separate platform downloads and previews to the website.

## 1.5.1

- Match the app icon to the website's forest green, warm off-white, and pale sage palette. Flatten the glossy blue treatment while preserving the stacked-session and play-cutout identity.
- Update the app icon package, website mark, favicon, and native app previews together.

## 1.5.0

- Add Check for updates in the library sidebar and menubar options. Sparkle downloads, verifies, installs, and relaunches updates from a signed release feed.
- Sign update archives and feeds with Ed25519 and verify them in the release workflow. Package Sparkle's helpers and preserve framework symlinks. Version comparisons use the release version consistently across local and CI builds.
- Add a persistent default editor, with installed VS Code, Cursor, Windsurf, Zed, and other editors detected automatically, plus a chooser for any editor application.
- Open the selected session's project in its editor and copy its resume command only after the editor opens successfully. Report missing folders/editors without changing the clipboard.
- Keep sidebar navigation scrollable in compact windows while editor, terminal, and update controls stay available.

## 1.4.2

- Make the entire project card, session row, navigation row, and assistant filter clickable, including transparent padding and space between labels.
- Give copy, library, note, history, cancel, and other small text/icon actions padded hit areas, with press feedback and disabled states.
- Enlarge sidebar rows and options menu labels, label icon-only controls for accessibility, and keep the capture popup within its available space.
- Add mouse-event regression tests covering empty row space, icon padding, control boundaries, and disabled actions.

## 1.4.1

- Keep a single running Reprise instance across installed and build-folder copies, preventing duplicate menubar icons and concurrent library writers.
- Bring the existing library forward when another copy is opened. Release the instance lock automatically on quit or crash.
- Replace the app icon from scratch with blue stacked session cards and a play cutout, plus a matching monochrome menubar symbol.

## 1.4.0

- Automatically discover Grok Build sessions from `~/.grok/sessions` or `$GROK_HOME/sessions`, reading only bounded `summary.json` metadata.
- Import authoritative session IDs, project folders, and saved activity times without reading transcripts or retaining generated conversation summaries.
- Include Grok sessions in grouped projects, assistant filters, session history, copy actions, and Terminal/Ghostty/iTerm2 resumption.
- Use the installed Grok Build syntax `grok --resume ID`, migrating older saved Grok commands on load.
- Keep Grok client source Unknown because its shared metadata format does not distinguish TUI, headless, and ACP. Manual source overrides remain supported.

## 1.3.0

- Distinguish recorded session sources: Desktop app, CLI, IDE extension, SDK / automation, Multiple clients, and Unknown. Codex uses specific originator metadata; Claude uses transcript entrypoints.
- Add source labels to session history and an All sources filter alongside project search. Source filtering keeps sessions grouped by project directory.
- Enrich previously imported sessions on sync without creating duplicates or overwriting notes, project edits, or manual source corrections.
- Add a manual source selector to capture review and Session details, with recorded metadata available for inspection. Missing or ambiguous metadata stays Unknown.
- Source labels describe local coding-session metadata; cloud-only Claude chats are not imported, and Resume still opens your selected terminal.

## 1.2.1

- Choose a persistent default terminal from the library sidebar or menubar menu: Apple Terminal, Ghostty, or iTerm2.
- Resume actions show the selected app and open a new window in the project directory. Ghostty uses its native surface configuration API and requires version 1.3 or later.
- Report a missing app, unsupported Ghostty version, or denied Automation permission instead of silently using another terminal.

## 1.2.0

- Organise the library by project directory instead of repeating the project name for every session. Codex and Claude sessions share one project row; different directories remain distinct even when their names match.
- Resume the latest session by default, choose from four recent sessions, or expand the complete project history. Search includes older notes without splitting the project into repeated rows.
- Move captures without a project folder into Unassigned, with an explanation and a folder-assignment action. Preserve all saved entries. Internal `.codex`, `.claude`, and `.chatgpt` workspace paths have their own Internal view.
- Add permanent library navigation, compact project summaries, and separate session detail controls. Menubar recents also show each project once.
- Rebuild the download website around screenshots of the real native app, with light/dark preview controls, direct release downloads, and installation/grouping FAQs.

## 1.1.1

- Refine the app icon with a smooth graphite tile, bold ivory terminal-return mark, and sage cursor. Transparent outer corners replace the old dark square backdrop.
- Add a matching monochrome menubar mark that adapts to macOS appearance.
- Update the website's app mark and ensure the icon package includes an exact 1024px master.

## 1.1.0

- Automatically discover local Codex and Claude sessions at startup and every 30 seconds while the app runs. Toggle discovery or refresh manually.
- Resume a selected session in Apple Terminal, starting in its project directory. Folder paths and arguments are safely quoted and missing directories are reported.
- Replace the cramped library rows with a searchable session list and a full detail pane. Increase text size, improve selection contrast, and support light/dark appearances.
- Edit project names, folders, commands, and notes; choose moved folders and reveal projects in Finder.
- Add manual command entry alongside screenshot OCR, larger capture controls, and an always-visible library link.
- Avoid duplicate imports, preserve edited context, confirm removal, and allow removed sessions to be restored from the library menu.
- Use Claude's working `claude --resume ID` syntax; continue using `codex resume ID` for Codex.
- Ignore obsolete OCR results after a capture is cancelled or replaced. Preserve unreadable library files instead of overwriting them.
- Separate the browser prototype's build output from the native release artifacts and run the native workflow tests in release CI.

Automatic discovery uses local transcript metadata and does not copy conversation content. Terminal launch requires an installed, authenticated CLI and macOS Automation permission. Releases remain ad-hoc signed rather than Apple notarized.
