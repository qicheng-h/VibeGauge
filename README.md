# Codex + Claude Credits Widget

Native macOS floating widget for Claude Code and OpenAI Codex quota windows.

## Build

```sh
./build-widget.sh
```

## Claude Code Setup

Claude Code exposes five-hour and seven-day quota windows through status line input. Install the capture wrapper once:

```sh
./install-claude-statusline-capture.sh
```

The wrapper preserves your existing status line command and writes the latest status payload to:

```sh
~/.claude/codex-credits-status.json
```

## Run

```sh
open "Codex Credits.app"
```

You can also double-click `Codex Credits.app` in Finder.

Controls:

- Click `x` on the widget to quit.
- Click `T` to toggle always-on-top mode.
- Click `r` to refresh live quota data.
- Right-click the widget to refresh or quit.
- Press `Esc` while the widget is focused to quit.
- The widget checks for updates every two minutes and skips full reloads when Claude/Codex source files have not changed.

Data sources:

- Codex reads the latest `rate_limits` event from `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Claude Code reads current-session and weekly quota windows from `rate_limits` captured from status line input.
- Context-window usage is intentionally not used because it is not subscription quota.
