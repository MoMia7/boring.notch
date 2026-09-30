<h1 align="center">
  <img src="docs/notch-agent-icon.png" alt="Notch Agent" width="128"><br>
  Notch Agent
</h1>

<p align="center">An AI agent that lives in your MacBook's notch. Hold a key, say what you want, let go.</p>

Notch Agent is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) that adds:

- **Push-to-talk.** Hold **Right Option (⌥)**, speak, release. Speech is transcribed on-device by Apple's speech model (macOS 26+), and music is lowered while you talk.
- **Instant actions.** Simple requests are routed by [Jev](https://typesafe.ai), a fast decision model, and run in a few hundred milliseconds without an LLM:
  - volume, brightness and media keys
  - "open Slack"
  - dark mode, screenshots
  - "play Bohemian Rhapsody", "play my gym playlist" (Spotify)
  - "remind me to call mom at 6", "block 2 to 3pm tomorrow for gym", "timer 10 minutes" (a countdown appears in the notch)
  - any of your **Shortcuts** by name ("run my morning routine")
- **A real agent for everything else.** Other requests go to [opencode](https://opencode.ai) running in the background, using ChatGPT, an API key, or a local model. Every shell command or file edit asks for your approval in the notch.
- **Live status.** The notch shows the tool being run, progress, retries, and elapsed time. Results pop up when you weren't looking.
- **Ambient nudges (optional).** Offers to help with new downloads, meetings about to start, and low battery.
- **Replaces boring.notch.** If boring.notch is installed, Notch Agent brings its settings over and moves it to the Trash, so the two don't fight over the notch. Everything boring.notch does is still here.
- **Updates itself.** New releases install automatically (Sparkle).

## Install

1. Download **Notch Agent.dmg** from [Releases](../../releases/latest) and drag it to Applications.
2. The app isn't notarized, so macOS blocks the first launch. Right-click the app → **Open** → **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Notch Agent.app"
   ```
3. Set up the background agent (installs opencode and a login service):
   ```sh
   curl -fsSL https://raw.githubusercontent.com/MoMia7/boring.notch/main/agent/setup.sh | zsh
   ```
4. The first-launch guide walks you through the rest. You can come back to it any time in **Settings → Notch Agent → Agent → Setup**:
   - **Models:** log in with ChatGPT (Plus/Pro) or add an API key for any provider.
   - **Jev:** paste a [TypeSafe](https://console.typesafe.ai) API key to enable instant actions. It costs about a cent a day.
   - **Spotify** (optional, Premium): create a free app at the [Spotify developer dashboard](https://developer.spotify.com/dashboard) with the redirect URI shown in Settings, paste the Client ID, and click Connect.
5. Grant **Accessibility** (for the push-to-talk key) and **Microphone** when asked.

Requires macOS 14+. Voice input needs macOS 26+.

## Development

- `swift test` runs the parsing tests (music queries, levels, durations, dates).
- `bun test agent/local-gemma` runs the local-model proxy tests.
- `scripts/release.sh` builds, signs and packages `Notch-Agent.dmg`, and adds a signed entry to `appcast.xml`. Publish the DMG as a GitHub release `v<version>`, then commit `appcast.xml`.

## Local model (advanced)

`agent/local-gemma/proxy.ts` lets opencode use a local llama.cpp model (tested with Gemma 4 26B) with working tool calls. It converts Gemma's native tool-call syntax, repairs misspelled arguments, and reports live progress to the notch. Run it with Bun and point an opencode provider at `http://127.0.0.1:8081/v1`.

## Credits

Built on [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam, licensed under GPL-3.0. This fork is distributed under the same license. The original README follows.

---

<h1 align="center">
  <br>
  <a href="http://theboring.name"><img src="https://framerusercontent.com/images/RFK4vs0kn8pRMuOO58JeyoemXA.png?scale-down-to=256" alt="Boring Notch" width="150"></a>
  <br>
  Boring Notch
  <br>
</h1>


<p align="center">
  <a title="Crowdin" target="_blank" href="https://crowdin.com/project/boring-notch"><img src="https://badges.crowdin.net/boring-notch/localized.svg"></a>
  <img src="https://github.com/TheBoredTeam/boring.notch/actions/workflows/cicd.yml/badge.svg" alt="TheBoringNotch Build & Test" style="margin-right: 10px;" />
  <a href="https://discord.gg/c8JXA7qrPm">
    <img src="https://dcbadge.limes.pink/api/server/https://discord.gg/c8JXA7qrPm?style=flat" alt="Discord Badge" />
  </a>
  <a href="https://www.ko-fi.com/alexander5015">
    <img src="https://srv-cdn.himpfen.io/badges/kofi/kofi-flat.svg" alt="Ko-Fi" />
  </a>
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/14815?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-14815" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/14815" alt="TheBoredTeam%2Fboring.notch |    Trendshift" width="250" height="55"/></a>
</p>
<!--Welcome to **Boring.Notch**, the coolest way to make your MacBook's notch the star of the show! Forget about those boring status bars—our notch turns into a dynamic music control center, complete with a snazzy visualizer and all the music controls you need. It's like having a mini concert right at the top of your screen! -->

Say hello to **Boring Notch**, the coolest way to make your MacBook’s notch the star of the show! Say goodbye to boring status bars: with Boring Notch, your notch transforms into a dynamic music control center, complete with a vibrant visualizer and all the essential music controls you need. But that’s just the start! Boring Notch also offers calendar integration, a handy file shelf with AirDrop support, a complete MacOS HUD replacement and more!

<p align="center">
  <img src="https://github.com/user-attachments/assets/2d5f69c1-6e7b-4bc2-a6f1-bb9e27cf88a8" alt="Demo GIF" />
</p>

<!--https://github.com/user-attachments/assets/19b87973-4b3a-4853-b532-7e82d1d6b040-->
---
<!--## Table of Contents
- [Installation](#installation)
- [Usage](#usage)
- [Roadmap](#-roadmap)
- [Building from Source](#building-from-source)
- [Contributing](#-contributing)
- [Join our Discord Server](#join-our-discord-server)
- [Star History](#star-history)
- [Buy us a coffee!](#buy-us-a-coffee)
- [Acknowledgments](#-acknowledgments)-->

## Installation

**System Requirements:**
- macOS **14 Sonoma** or later
- Apple Silicon or Intel Mac

---

### Option 1: Download and Install Manually

<a href="https://github.com/TheBoredTeam/boring.notch/releases/latest/download/boringNotch.dmg" target="_self"><img width="200" src="https://github.com/user-attachments/assets/e3179be1-8416-4b8a-b417-743e1ecc67d6" alt="Download for macOS" /></a>

Once downloaded, open the `.dmg` and move **Boring Notch** to your `/Applications` folder.

> [!IMPORTANT]
> We don't have an Apple Developer account (yet 👀), so macOS will warn you that Boring Notch is from an unidentified developer on first launch. This is expected behavior.
>
> You'll need to bypass this before the app will open. You only need to do this once. Use one of the methods below.

---

#### Recommended: Terminal (Always Works)

This is the quickest and easiest method. It only requires a single command and works consistently for all users. System Settings can sometimes fail and won't work for non-admin users.

After moving Boring Notch to your Applications folder, run:

```bash
xattr -dr com.apple.quarantine "/Applications/Boring Notch.app"
```

Then open the app normally.

---

#### Alternative: System Settings

> [!NOTE]
> This method doesn't work for all users. If this doesn't work, use the Terminal method above.

1. Try to open the app — you'll see a security warning.
2. Click **OK** to dismiss it.
3. Open **System Settings** > **Privacy & Security**.
4. Scroll to the bottom and click **Open Anyway** next to the Boring Notch warning.
5. Confirm if prompted.

---

### Option 2: Install via Homebrew

You can also install using [Homebrew](https://brew.sh). The Homebrew installation automatically bypasses the macOS security warning described above.

```bash
brew install --cask TheBoredTeam/boring-notch/boring-notch
```

## Usage

- Launch the app, and voilà—your notch is now the coolest part of your screen.
- Hover over the notch to see it expand and reveal all its secrets.
- Use the controls to manage your music like a rockstar.
- Click the star in your menu bar to customize your notch to your heart's content.

## 📋 Roadmap
- [x] Playback live activity 🎧
- [x] Calendar integration 📆
- [x] Reminders integration ☑️
- [x] Mirror 📷
- [x] Charging indicator and current percentage 🔋
- [x] Customizable gesture control 👆🏻
- [x] Shelf functionality with AirDrop 📚
- [x] Notch sizing customization, finetuning on different display sizes 🖥️
- [x] System HUD replacements (volume, brightness, backlight) 🎚️💡⌨️
- [ ] Bluetooth Live Activity (connect/disconnect for bluetooth devices) 
- [ ] Weather integration ⛅️
- [ ] Customizable Layout options 🛠️
- [ ] Lock Screen Widgets 🔒
- [ ] Extension system 🧩
- [ ] Notifications (under consideration) 🔔
<!-- - [ ] Clipboard history manager 📌 `Extension` -->
<!-- - [ ] Download indicator of different browsers (Safari, Chromium browsers, Firefox) 🌍 `Extension`-->
<!-- - [ ] Customizable function buttons 🎛️ -->
<!-- - [ ] App switcher 🪄 -->

<!-- ## 🧩 Extensions
> [!NOTE]
> We’re hard at work on some awesome extensions! Stay tuned, and we’ll keep you updated as soon as they’re released. -->

## Building from Source

### Prerequisites

- **macOS 15.6 or later**
- **Xcode 26 or later**

### Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/TheBoredTeam/boring.notch.git
   cd boring.notch
   ```

2. **Open the Project in Xcode**:
   ```bash
   open boringNotch.xcodeproj
   ```

3. **Build and Run**:
    - Click the "Run" button or press `Cmd + R`. Watch the magic unfold!

## 🤝 Contributing

We’re all about good vibes and awesome contributions! Read [CONTRIBUTING.md](CONTRIBUTING.md) to learn how you can join the fun!

## Join our Discord Server

<a href="https://discord.gg/GvYcYpAKTu" target="_blank"><img src="https://iili.io/28m3GHv.png" alt="Join The Boring Server!" style="height: 60px !important;width: 217px !important;" ></a>

## Star History
<!-- BROKEN: GitHub now restricts the stargazer API for privacy reasons
<a href="https://www.star-history.com/#TheBoredTeam/boring.notch&Timeline">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=TheBoredTeam/boring.notch&type=Timeline&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=TheBoredTeam/boring.notch&type=Timeline" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=TheBoredTeam/boring.notch&type=Timeline" />
 </picture>
</a>
-->
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/TheBoredTeam/org-star-chart-updater/main/projects/boring.notch/chart-dark.svg">
   <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/TheBoredTeam/org-star-chart-updater/main/projects/boring.notch/chart-light.svg">
   <img src="https://raw.githubusercontent.com/TheBoredTeam/org-star-chart-updater/main/projects/boring.notch/chart-light.svg" alt="TheBoredTeam/boring.notch GitHub star history">
 </picture>

## Support us on Ko-fi!
<!-- <a href="https://www.buymeacoffee.com/jfxh67wvfxq" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-red.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a> -->
<a href="https://www.ko-fi.com/alexander5015" target="_blank"><img src="https://github.com/user-attachments/assets//a76175ef-7e93-475a-8b67-4922ba5964c2" alt="Support us on Ko-fi" style="height: 70px !important;width: 346px !important;" ></a>

## 🎉 Acknowledgments

We would like to express our gratitude to the authors and maintainers of the open-source projects that made this possible. 

## Notable Projects
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** –  An open-source project that allowed us to use the Now Playing source in macOS 15.4+
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** – An open-source project that has been instrumental in developing the first version of the "Shelf" feature in Boring Notch.

For a full list of licenses and attributions, please see the [Third-Party Licenses](./THIRD_PARTY_LICENSES.md) file.

### Icon credits: [@maxtron95](https://github.com/maxtron95)
### Website credits: [@himanshhhhuv](https://github.com/himanshhhhuv)

- **SwiftUI**: For making us look like coding wizards.
- **You**: For being awesome and checking out **boring.notch**!

