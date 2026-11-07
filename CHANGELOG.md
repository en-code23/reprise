# Release notes

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
