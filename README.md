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

Hypercode updates itself: it checks for a new release once a day and asks before installing it. Check by hand with **Hypercode › Check for Updates…**, or let it install updates in the background under **Settings › General › Updates**.

### Build from source

```sh
curl -fsSL https://raw.githubusercontent.com/alexisbcz/hypercode/main/install.sh | bash
```

It also links a `hypercode` command into your PATH, so `hypercode .` opens the folder you're in, like VS Code's `code .`. To add it later, use **Hypercode › Install ‘hypercode’ Command in PATH**.

## Voice

Everything runs on your Mac. Pick the engines under **Settings › General**.

- **Dictation:** press ⇧⌘D in the composer to speak a prompt. Apple's speech recognizer types as you talk; [LFM3-Audio-2B](https://huggingface.co/LiquidAI/LFM3-Audio-2B) transcribes when you stop, in 18 languages, through a `llama-server` that Hypercode starts itself.
- **Read aloud:** replies are read with Kyutai's Pocket TTS, LFM3-Audio (male and female voices, 19 languages and accents), or the macOS voices.

LFM3-Audio's first use downloads llama.cpp (about 16 MB) from its GitHub release and the model (about 2.2 GB) from Hugging Face into `~/Library/Application Support/Hypercode/LFM3`. The model is under the [LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM3-Audio-2B/blob/main/LICENSE).

## Releasing

1. Set `MARKETING_VERSION` in `project.yml` to the new version, so builds from source know which release they match.
2. Tag it and push the tag:

   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   ```

The Release workflow builds the DMG, signs it for Sparkle, and publishes it with an `appcast.xml`, which installed copies read from the latest release. Signing needs the `SPARKLE_PRIVATE_KEY` repository secret, the private half of the `SUPublicEDKey` in `Hypercode/Info.plist`. Sparkle's `generate_keys` (in `build/SourcePackages/artifacts/sparkle/Sparkle/bin` after a build) keeps it in your keychain; `generate_keys -x key.txt` exports it. Keep a backup: without it, installed copies can't take updates.

`make dmg` builds the same DMG locally.

[MIT License](LICENSE)
