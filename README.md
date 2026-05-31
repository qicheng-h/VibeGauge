# Codex + Claude Credits Widget

Native macOS floating widget for Claude Code and OpenAI Codex quota windows.

## Build

```sh
./build-widget.sh
```

## Claude Code Setup

The widget first tries to read Claude's own `/usage` response from the Claude desktop app HTTP cache. This does not read Claude cookies or tokens, but it does require `zstd` to decompress the cached response. On this machine Homebrew installs it at:

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

## Run

```sh
open "Codex Credits.app"
```

You can also double-click `Codex Credits.app` in Finder.

Controls:

- Click `x` on the widget to quit.
- Click `T` to toggle always-on-top mode.
- Click `r` to refresh live quota data.
- Drag the dotted handle at the top center to move the widget.
- Hold `Command` or `Option` and drag anywhere on the widget to move it.
- Right-click the widget to switch style, switch light/dark appearance, refresh, or quit.
- Press `Esc` while the widget is focused to quit.
- The widget redraws countdowns every 30 seconds and checks source-file changes every two minutes.

Styles:

- `Native`: macOS glass-style panel.
- `Mono`: dense terminal-style text panel.
- `Playful`: rounded card layout.
- `Terminal`: retro sage/phosphor layout.

Data sources:

- Codex reads the latest `rate_limits` event from `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Claude Code reads current-session and weekly quota windows from Claude desktop's cached `/usage` response, then falls back to `rate_limits` captured from status line input.
- Context-window usage is intentionally not used because it is not subscription quota.
