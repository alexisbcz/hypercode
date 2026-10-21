<p align="center">
  <img src="docs/icon.png" width="128" alt="Hypercode app icon">
</p>

# Hypercode

A native macOS app for running Claude Code sessions.

![Hypercode showing a Claude Code session](docs/screenshot.png)

## Installation

### Download

Get `Hypercode-<version>.dmg` from the [latest release](https://github.com/alexisbcz/hypercode/releases/latest), open it, and drag Hypercode into Applications. It needs a Mac with Apple silicon on macOS 26 or later, and the Claude Code CLI installed.

The app isn't notarized, so macOS blocks the first launch. Allow it under **System Settings › Privacy & Security › Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Hypercode.app
```

To get the `hypercode` command, use **Hypercode › Install ‘hypercode’ Command in PATH**.

### Build from source

```sh
curl -fsSL https://raw.githubusercontent.com/alexisbcz/hypercode/main/install.sh | bash
```

It also links a `hypercode` command into your PATH, so `hypercode .` opens the folder you're in, like VS Code's `code .`. To add it later, use **Hypercode › Install ‘hypercode’ Command in PATH**.

[MIT License](LICENSE)
