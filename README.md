<p align="center">
  <img src="assets/app_icon.png" width="112" alt="Mac Mop app icon">
</p>

<h1 align="center">Mac Mop</h1>

<p align="center">
  <strong>A Mac cleaner that tells you what every file is before you remove it.</strong><br>
  Free, open source, native. Everything it cleans goes to the Trash, so you can take it back.
</p>

<p align="center">
  <a href="https://github.com/maimorto/mac-mop/releases/latest"><img src="assets/readme/download.svg" width="300" alt="Download Mac Mop for Mac. Free, macOS 14 or later, Apple silicon."></a>
</p>

<p align="center">
  <a href="https://github.com/maimorto/mac-mop/releases/latest"><img src="https://img.shields.io/github/v/release/maimorto/mac-mop?label=release&color=2f6fed" alt="Latest release"></a>
  <a href="https://github.com/maimorto/mac-mop/releases"><img src="https://img.shields.io/github/downloads/maimorto/mac-mop/total?color=2f6fed" alt="Total downloads"></a>
  <a href="https://github.com/maimorto/mac-mop/stargazers"><img src="https://img.shields.io/github/stars/maimorto/mac-mop?color=7c4dff" alt="GitHub stars"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-0c1230" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-BSD--3--Clause-0c1230" alt="BSD 3-Clause license"></a>
</p>

<p align="center">
  <a href="#see-it">Screenshots</a> ·
  <a href="#install">Install</a> ·
  <a href="#what-it-does">Features</a> ·
  <a href="#in-your-menu-bar">Menu bar</a> ·
  <a href="#how-it-keeps-your-files-safe">Safety</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="README.it.md">Italiano</a>
</p>

<p align="center">
  <img src="assets/readme/en/hero.jpg" width="920" alt="Mac Mop's Cleanup page in dark mode after a scan: 9.92 GB selected, and each category (package manager caches, user cache files, universal binaries) has a plain description and a label that says Rebuilds itself or Review first">
</p>

<p align="center">
  <img src="assets/readme/stats.svg" width="880" alt="594 Apple XProtect rules run on demand. 301 automated tests. 13 languages. 0 trackers, accounts or ads.">
</p>

Most cleaners show a number and a big button. Mac Mop shows the same number, then says what is behind it: what each group of files is, whether macOS makes it again on its own, and what changes if it goes. Anything that holds your own data starts unchecked.

## See it

<table>
<tr>
<td width="50%"><img src="assets/readme/en/system-data.jpg" alt="The System Data page: the total split into virtual machines, app data, wallpaper videos, Apple Intelligence models and more, each marked safe, to review or protected"></td>
<td width="50%"><img src="assets/readme/en/space-lens.jpg" alt="Space Lens: a coloured map of a folder where the biggest subfolders are the biggest tiles, with a list of the largest items on the right"></td>
</tr>
<tr>
<td><strong>"System Data", opened up.</strong> Every part is measured on your Mac and marked safe, to review, or protected by macOS. Each byte is counted once, and the next scan shows what grew.</td>
<td><strong>Where the disk went.</strong> A live map of any folder, plus large and old files, duplicates, Time Machine snapshots and other space macOS hides.</td>
</tr>
<tr>
<td width="50%"><img src="assets/readme/en/malware.jpg" alt="The Malware page: scan depth from Quick to Deep, what Apple's XProtect has done recently, and a weekly scan switch"></td>
<td width="50%"><img src="assets/readme/en/apple-privacy.jpg" alt="The Apple privacy page: switches for personalised ads and Siri data sharing, and how much disk the Apple Intelligence models take"></td>
</tr>
<tr>
<td><strong>Mac malware checks.</strong> All of Apple's XProtect rules already on your Mac (594 today), not only the file hashes. Plus what starts at login, your shell history, and a warning when the clipboard holds a command you should not paste.</td>
<td><strong>Privacy switches.</strong> What you share with Apple for ads, analytics and Siri, on one page. Browser caches and history for six browsers, without touching passwords, cookies or wallet extensions.</td>
</tr>
<tr>
<td width="50%"><img src="assets/readme/en/maintenance.jpg" alt="The Maintenance page: safe tasks such as flushing the DNS cache and verifying the startup disk, each with a one-line explanation and a Run button, then advanced tasks"></td>
<td width="50%"><img src="assets/readme/en/done.jpg" alt="The page shown after a cleanup: a green check mark, the space freed, and a link to Cleanup History"></td>
</tr>
<tr>
<td><strong>Maintenance, explained.</strong> Safe tasks first, each with one line on what it does. Advanced ones only when you ask.</td>
<td><strong>Undo exists.</strong> Cleaned files go to the Trash, and Cleanup History puts them back where they were.</td>
</tr>
</table>

## In your menu bar

<p align="center">
  <img src="assets/readme/en/menu-bar.jpg" width="920" alt="Four Mac Mop menu bar panels side by side: the home panel with recommendations and a Mac overview, the CPU panel with usage and cores, the memory panel with pressure and top processes, and the battery panel with health and cycle count">
</p>

Mac Mop also lives in the menu bar, as small items you can switch on one by one in Settings › Menu Bar.

- **Live numbers in the bar.** Memory, battery, network speed and CPU, each as its own compact item, with free disk space next to the mop.
- **A panel behind each one.** CPU (usage, load, per-core bars), GPU, memory (pressure gauge, what is compressed or swapped), disk (read and write speed), network (speed, latency, local address) and battery (health, cycle count, temperature, power draw).
- **Who is using what.** Each panel lists the top processes for that resource.
- **A home panel.** How much you can safely free right now, the state of your protection, connected drives with an Eject button, and one click to start a cleanup.
- **A clipboard guard.** If you copy one of those "paste this into Terminal" commands, a warning appears before you paste it.

## Install

1. Download `MacMop-<version>.dmg` from the [latest release](https://github.com/maimorto/mac-mop/releases/latest).
2. Open it and drag Mac Mop into Applications.
3. Open Mac Mop. It is not notarized by Apple yet, so the first time macOS blocks it: go to System Settings › Privacy & Security, scroll down and click **Open Anyway**.

Needs macOS 14 Sonoma or later on Apple silicon (M1 or newer). It looks best on macOS 26 Tahoe and later. An Intel build is not available yet: see [Contributing](#contributing).

> [!CAUTION]
> Mac Mop is published only in this repository. It is free. A site that sells it, or that asks you to paste a command into Terminal to get it, is not mine.

## What it does

| | |
|---|---|
| **Cleanup** | System junk, app caches, logs, old installers, mail attachments, Xcode and developer caches, project build folders. Every category has a label and a plain description. |
| **System Data** | The line macOS never explains, split into its parts and measured on your Mac. |
| **Space Lens** | A live disk map, large and old files, duplicates (removed, or turned into APFS clones that take no extra space), Time Machine snapshots. |
| **Apps** | Uninstall an app with what it left behind, and see why each file belongs to it. Find apps you no longer open. Remove files that `.pkg` installers scattered around. |
| **Malware** | Apple's XProtect rules run on demand, behaviour rules for today's stealers, shell history check, weekly scan, optional quarantine. |
| **Security check** | FileVault, Gatekeeper, firewall, System Integrity Protection and more, with the steps to fix what is off. |
| **Privacy** | Apple's ad and analytics switches, browser traces, saved Wi-Fi networks, app permissions. |
| **Performance** | Login items and background agents (anything you switch off can be switched back on), maintenance tasks, open network ports. |
| **Mac health** | One score out of 100, and the things that would raise it most. |
| **Menu bar** | Live CPU, GPU, memory, disk, network and battery, with a panel for each. |

## How it keeps your files safe

- **Almost everything can come back.** Cleaned files go to the Trash. Cleanup History puts them back where they were.
- **Your data starts unchecked.** Each category has a label: *Rebuilds itself*, *Safe*, or *Review first*. Only the first two are selected for you.
- **You can rehearse.** *Dry run* goes through the whole cleanup and shows what would move, without moving it.
- **Checked again at the last moment.** Right before a file moves, Mac Mop checks it against its rules once more, in case something changed since the scan.
- **Some places are off limits.** Passwords, cookies, wallet data and files macOS protects are shown, never selected.

## Privacy

No analytics, no account, no ads. Your files never leave your Mac. This is every network request Mac Mop can make:

- **App updates page, when you run it:** for each installed app that declares a Sparkle update feed, it reads that feed (the same URL the app itself would check) to see if a newer version exists.
- **MalwareBazaar, only if you add your own free abuse.ch key** in Settings: it downloads the hash list. Without a key, it never contacts abuse.ch.
- **Menu bar › Network panel, only while it is open:** it opens a TCP connection to `1.1.1.1:443` to measure latency. Nothing is sent over it.

Mac Mop does not check for its own updates in this version: watch the repository's releases to hear about new ones.

The clipboard warning reads copied text on your Mac to spot "paste this into Terminal" attacks; it is never stored, logged or sent.

`scripts/check-network-surface.py` fails the build if the app gains a network call that is not on this list.

## What it doesn't do

- **It doesn't block malware before it runs.** That needs an entitlement Apple grants to security vendors. Mac Mop scans on demand and once a week, watches a few folders, and tells you what it found.
- **It isn't notarized yet.** Hence the extra step on first open. You can read the code and build it yourself instead.
- **It won't make a healthy Mac faster.** It frees disk space and shows what runs in the background.

## Languages

English, Italiano, Deutsch, Español, Português (Brasil), Français, 日本語, 한국어, Русский, Türkçe, فارسی, 简体中文, 繁體中文. The app follows your Mac's language, or the one you pick in Settings.

## Build from source

```bash
git clone https://github.com/maimorto/mac-mop.git
cd mac-mop
./scripts/build-dmg.sh --app-only
open ".build/dmg/Mac Mop.app"
```

Needs Xcode 26 or the Command Line Tools. See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and how strings are translated.

## Contributing

Bug reports and pull requests are welcome. A wrong label on a category ("Safe" on something that isn't) is the most useful bug you can report: please [open an issue](https://github.com/maimorto/mac-mop/issues/new/choose) with the path.

## Star history

If Mac Mop gave you some disk space back, a star helps the next person with a full disk find it.

<p align="center">
  <a href="https://star-history.com/#maimorto/mac-mop&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=maimorto/mac-mop&type=Date&theme=dark">
      <img src="https://api.star-history.com/svg?repos=maimorto/mac-mop&type=Date" width="640" alt="Chart of GitHub stars for maimorto/mac-mop over time">
    </picture>
  </a>
</p>

## License

BSD 3-Clause, see [LICENSE](LICENSE). Code and data reused from other open-source projects are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
