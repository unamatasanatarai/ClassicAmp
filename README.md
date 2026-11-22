# ClassicAmp

**The classic skinnable desktop music player, rebuilt natively for modern Macs: gapless, offline, and small enough to live beside your work.**

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="ClassicAmp app icon" />
</p>

A native Swift/AppKit player for your local music. Its three classic windows (player, equalizer and playlist) snap together like hardware modules, it loads classic `.wsz` skins as they are, and it plays FLAC + CUE albums without gaps. No accounts, no streaming, no third-party dependencies.

<p align="center">
  <a href="https://github.com/unamatasanatarai/ClassicAmp/releases/latest"><b>⬇ Download the latest release</b></a>
  &nbsp;·&nbsp; macOS 12+ &nbsp;·&nbsp; Intel & Apple Silicon (Universal)
</p>

<p align="center">
  <img alt="Swift 5.7" src="https://img.shields.io/badge/Swift-5.7-F05138?logo=swift&logoColor=white">
  <img alt="macOS 12+" src="https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white">
  <img alt="License: GPL-2.0" src="https://img.shields.io/badge/license-GPL--2.0-blue">
</p>

---

## Why It Exists

Most music apps today are streaming clients: one large window, an account, and a library that lives on someone else's server. This project goes back to the model that made desktop players great:

- **Your files, played locally.** Point it at a folder and it plays. Nothing to sign up for.
- **A compact player.** The player is 275 × 116 points and can roll up to a 14-pixel strip.
- **The look is yours.** Load any classic `.wsz` skin and the whole player changes, from bitmap fonts to visualizer colours.

## What You Get

### 🎧 Gapless playback, CUE sheets included
Tracks move to the next one with no gap or re-buffering. Single-file albums split into proper tracks using external `.cue` sheets or the CUE sheet embedded in a FLAC file. Plays MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, CAF, Ogg and Opus.

### 🎚 10-band equalizer with presets
10 bands plus preamp, with a live response curve. It ships 18 classic presets (Rock, Classical, Full Bass & Treble, Laptop/Headphones and more) and lets you save your own. **AUTO** picks a preset from each track's genre tag.

### 🧲 Snap-together windows
Drag the main window and the windows glued to it move together. Drag a window near another and it snaps into place. Also available:
- **Window shade:** each window rolls up to a slim bar that keeps working controls.
- **Double Size:** scales every window 2×.
- **Always on Top:** keeps the player above other windows.

### 🎨 Real skin support
Classic `.wsz` skins load directly, with no external unzip tool. The skin's playlist colours, visualizer palette and window shapes (`REGION.TXT`) are all applied, and anything a skin is missing falls back to the bundled base skin. Even the menus and the quit prompt are drawn in the skin's style.

### 📊 Live visualizer
Spectrum analyzer with falling peaks, or an oscilloscope, in the skin's colours. It stops drawing when the window is hidden, so a background player costs almost nothing.

### ⚡ Built for big libraries
Library imports read files in parallel. Playlists can be sorted by title, filename, path or duration, reversed, randomized or saved as M3U/PLS. **Jump to File** (`J`) finds any track as you type.

### ⌨️ Keyboard-first, Mac-native
- **Classic keys:** `Z X C V B` for previous, play, pause, stop and next. Arrow keys seek and change volume.
- **Media keys:** your keyboard's media keys work, including when macOS's remote-control daemon is disabled.
- **Menu bar:** a status icon brings the player to the front with a left-click and opens a full menu with a right-click. The Dock icon is optional.

### 💾 Picks up where you left off
Window layout, docking, skin, EQ, volume, playlist, selection and playback position are restored on the next launch.

## How It Works

```text
1. Drop files or folders onto any window (or press L, or use Scan Music Library…)
2. The playlist fills: CUE sheets become tracks, unreadable files are skipped
3. Press X (or the play media key): playback is gapless, through the 10-band EQ
4. Load a .wsz skin (⌘K), snap the windows the way you like, roll them up when you need space
5. Quit: the layout, playlist and position are saved for next time
```

## Keyboard Reference

| Key | Action | Key | Action |
|---|---|---|---|
| `Z` / `B` | Previous / next track | `←` / `→` | Seek −5 s / +5 s |
| `X` / `C` / `V` | Play / pause / stop | `↑` / `↓` | Volume |
| `Space` | Play / pause | `M` | Mute |
| `S` / `R` | Shuffle / cycle repeat | `J` | Jump to file |
| `L` | Open files | `⌘K` | Load skin |
| `⌘1` `⌘2` `⌘3` | Toggle player / EQ / playlist | `⇧⌘D` | Double size |
| `⇧⌘T` | Always on top | `⌘Q` twice | Quit |

## Quick Start

**Use it:** download the DMG from [Releases](https://github.com/unamatasanatarai/ClassicAmp/releases/latest), open it, and drag the app into **Applications**.

**Build it** (Xcode command-line tools, no other dependencies):

```bash
git clone https://github.com/unamatasanatarai/ClassicAmp.git
cd ClassicAmp
make run      # build the universal .app and launch it
```

## Development

| Command | What it does |
|---|---|
| `make build` | Compile the universal (`x86_64` + `arm64`) app bundle into `build/` |
| `make run` | Kill running instances, rebuild, launch |
| `make test` | Build and run the native Swift test suite |
| `make monitor` | Live CPU and RAM of the running app, with history (`ARGS="-i 0.5 -l log.csv"`) |
| `make dmg` | Package the app in a styled, drag-to-install DMG |
| `make release <x.y.z>` | Test, build the DMG, tag and publish a GitHub release |
| `make revoke` | Reset macOS permissions and LaunchServices/QuickLook caches |
| `make clean` | Remove build artifacts |

- **Single-architecture builds:** `ARCHS=x86_64 make build` (or `arm64`) builds one architecture for faster iteration.
- **App name and bundle ID:** set in [`scripts/config.sh`](scripts/config.sh), or run `make setup`.
- **Toolchain:** the app is compiled directly with `swiftc`. There is no Xcode project and no package dependencies.

### Under the hood

| Area | Implementation |
|---|---|
| Audio | `AVAudioEngine`: player → 10-band EQ → balance → output. Tracks are scheduled back to back for gapless playback |
| Analysis | Accelerate/vDSP FFT with preallocated buffers |
| Skins | In-process ZIP reader, skin bitmap font, `PLEDIT.TXT` / `VISCOLOR.TXT` / `REGION.TXT` parsing |
| System | `MPRemoteCommandCenter` / Now Playing, raw media-key fallback, menu-bar status item |
| Persistence | JSON state, with the playlist written only when it changes |

### Releasing

```bash
export GEMINI_API_KEY="your-api-key"
make release 1.2.3
```

The release flow runs in three phases: **gather, ask, do**.
- **Gather:** validates the version and the clean working tree, collects the commits since the last tag, drafts release notes (a Gemini summary plus the full commit list) and runs the tests.
- **Ask:** shows the complete preview and waits for `yes`.
- **Do:** builds the DMG, commits, tags, pushes and publishes the GitHub release.

## License

[GNU General Public License v2.0](LICENSE)

> This is an independent, fan-made project. It is not affiliated with or endorsed by Winamp or Nullsoft.
