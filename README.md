# News Timer

A macOS menu bar app that dramatically plays news music before every meeting.

Inspired by [@rtwlz](https://x.com/rtwlz/status/2036082537949434164).

## Features

- **Countdown in the menu bar** — appears only when a meeting is < 15 minutes away
- **Blinks red** in the last 14 seconds
- **Plays a sound** at the 14-second mark (bring your own ~14s MP3)
- **Day picker** — set meetings for specific days of the week
- **Repeat weekly** or one-time
- **Persists across restarts** — meetings are saved automatically

## Download

👉 **[Download latest DMG from Releases](../../releases/latest)**

Open the DMG, drag `NewsTimer.app` to Applications, double-click to launch.
The app lives in the menu bar — no Dock icon.

> **Note:** The audio file is not included in this repo.
> See [Build from source](#build-from-source) if you want to use your own sound.

## Usage

1. Click the calendar icon in the menu bar
2. **Add Meeting…** → enter name, time (24h), pick days, weekly or one-time
3. Done — the app handles the rest

| State | Appearance |
|-------|-----------|
| > 15 min to meeting | Small calendar icon only |
| 15 min → 1 min | `((·)) Team sync in 4:32` |
| < 1 min | Orange tint |
| Last 14 sec | Red blinking + audio plays |
| Meeting started | `((·)) Team sync is live!` green |

## Build from source

**Requirements:** macOS 13+, Xcode Command Line Tools

```bash
# 1. Install Xcode CLI tools (skip if already installed)
xcode-select --install

# 2. Clone the repo
git clone https://github.com/YOUR_USERNAME/NewsTimer.git
cd NewsTimer

# 3. Add your own ~14 second MP3 countdown sound
#    Place it at: ~/Downloads/bbc news start up theme.mp3
#    (or edit the path in build.sh to point to your file)

# 4. Build
bash build.sh

# 5. Run
open NewsTimer.app
```

To package a DMG:

```bash
bash create_dmg.sh
```

## Project structure

```
NewsTimer/
├── Sources/
│   └── main.swift       # Full app (~300 lines of Swift)
├── Info.plist           # App bundle metadata
├── build.sh             # Compiles and creates .app
└── create_dmg.sh        # Packages .app into .dmg
```

No external dependencies — pure AppKit + AVFoundation.

## Requirements

- macOS 13 Ventura or later

## License

MIT
