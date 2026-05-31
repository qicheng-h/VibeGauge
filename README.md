# VibeGauge

A compact native macOS desktop widget for tracking Claude Code and OpenAI Codex quota usage.

## Quick Start

Build the app:

```sh
./build-widget.sh
```

Open it:

```sh
open "VibeGauge.app"
```

You can also double-click `VibeGauge.app` in Finder.

## What It Does

VibeGauge shows your current Claude Code and Codex quota windows in a small floating desktop widget:

- 5-hour and 7-day quota usage for Claude Code.
- 5-hour and 7-day rate-limit usage for Codex.
- Time remaining until each quota window refreshes.
- Relative data refresh age next to each service name.
- Automatic background refresh without blocking the widget UI.
- Native, Mono, and Terminal skins with light/dark appearance.
- Optional always-on-top behavior.

Usage bars are color-coded by quota usage:

- Green: 50% or below.
- Orange: above 50%.
- Red: 90% or above.

## Screenshots

For the GitHub project page, place desktop screenshots here:

```text
docs/assets/vibegauge-native.png
docs/assets/vibegauge-mono.png
```

Then add them to this section:

```md
![VibeGauge Native skin](docs/assets/vibegauge-native.png)
![VibeGauge Mono skin](docs/assets/vibegauge-mono.png)
```

Do not use the XHS marketing images for the GitHub README; use clean desktop screenshots instead.

## Claude Code Setup

VibeGauge first tries to read Claude's own `/usage` response from the Claude desktop app HTTP cache. This does not read Claude cookies or tokens, but it does require `zstd` to decompress the cached response. On this machine Homebrew installs it at:

```sh
/opt/homebrew/bin/zstd
```

If no readable cache is available, the widget falls back to Claude Code status line input. Install the capture wrapper once:

```sh
./install-claude-statusline-capture.sh
```

The wrapper preserves your existing status line command and writes the latest status payload to:

```sh
~/.claude/codex-credits-status.json
```

Restart Claude Code or open a new Claude Code session after installing this wrapper. Already-running sessions may keep the old status line command and will not update the capture file.

## Controls

- Click `x` on the widget to quit.
- Click the shirt button to cycle Native, Mono, and Terminal skins.
- Click the sun/moon button to toggle light/dark mode.
- Click the pin button to toggle always-on-top mode.
- Click the refresh button to refresh live quota data.
- Drag the dotted handle at the top center to move the widget.
- Hold `Command` or `Option` and drag anywhere on the widget to move it.
- Right-click the widget to choose an exact style, switch light/dark appearance, refresh, or quit.
- Hover any top button to see what it does.
- Press `Esc` while the widget is focused to quit.
- The widget redraws countdowns every 30 seconds and checks source-file changes every two minutes.

## Styles

- `Native`: macOS glass-style panel.
- `Mono`: dense terminal-style text panel.
- `Terminal`: retro sage/phosphor layout.

## Data Sources

- Codex reads the latest `rate_limits` event from `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Claude Code reads current-session and weekly quota windows from Claude desktop's cached `/usage` response, then falls back to `rate_limits` captured from status line input.
- Context-window usage is intentionally not used because it is not subscription quota.
