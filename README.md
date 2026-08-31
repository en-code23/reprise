# Reprise

Reprise is a native macOS menubar app that turns terminal screenshots into an organized library of AI coding-session resume commands.

Drop a screenshot on the Reprise status icon. Apple Vision OCR detects commands such as:

```sh
codex resume session-id
claude resume session-id
grok resume session-id
```

The app lets you review the detected assistant and command, add or detect the project directory, attach a project name and note, then copy the command later from a grouped local library. Screenshots are processed on-device and are never uploaded.

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
