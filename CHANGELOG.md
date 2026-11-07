# Release notes

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
