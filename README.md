# Kurotty

<p align="center">
  <img src="kurotty.png" alt="Kurotty" width="400" height="400">
</p>

<p align="center">
  <img src="kurotty-preview.gif" alt="Kurotty preview" width="700">
</p>

Kurotty is a native macOS terminal built for developers who work with coding agents such as Claude Code and Codex.

> Kurotty is currently an early alpha. It requires macOS 14 or newer.

## Install

1. [Download the latest Kurotty DMG](https://github.com/skyepodium/kurotty/releases/latest/download/kurotty-macos-universal.dmg).
2. Open the downloaded DMG.
3. Drag `kurotty.app` into the `Applications` folder.
4. Open Kurotty from Applications.

The download is a notarized Universal build for both Apple Silicon and Intel Macs. Checksums, release notes, and older versions are available on [GitHub Releases](https://github.com/skyepodium/kurotty/releases).

Kurotty can check for updates after installation. On first launch, macOS may ask for notification permission. Kurotty may also ask before adding optional status hooks for Claude Code or Codex; it does not change either agent's configuration without your approval.

## Highlights

- Native macOS tabs, split panes, menus, keyboard input, IME, clipboard, and preferences.
- Fast Metal rendering with truecolor, themes, scrollback, and terminal styling.
- Native local tmux windows and panes when you run `tmux -CC`.
- Command history, file explorer, Command Palette, and project-aware status bar.
- Coding-agent status, saved-session browsing, token and quota summaries, and git worktree awareness for Claude Code and Codex.

## For Contributors

Implementation details live in the [`docs`](docs/) directory. Start with the [architecture overview](docs/architecture.md).

## License

Kurotty is released under the MIT License.
