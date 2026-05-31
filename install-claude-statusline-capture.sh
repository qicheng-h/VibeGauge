#!/bin/zsh
set -euo pipefail

python3 - <<'PY'
import json
import os
import shlex
from pathlib import Path

home = Path.home()
settings_path = home / ".claude" / "settings.json"
wrapper_path = home / ".claude" / "codex-credits-statusline.sh"

settings = {}
if settings_path.exists():
    backup_path = settings_path.with_suffix(".json.codex-credits-backup")
    if not backup_path.exists():
        backup_path.write_text(settings_path.read_text())
    settings = json.loads(settings_path.read_text())

current = settings.get("statusLine", {})
current_command = current.get("command", "")
wrapper_command_prefix = str(wrapper_path)

wrapper_path.write_text("""#!/bin/bash
set -euo pipefail

input=$(cat)
state="${HOME}/.claude/codex-credits-status.json"
tmp="${state}.tmp"

printf "%s" "$input" > "$tmp"
mv "$tmp" "$state"

if [ -n "${CODEX_CREDITS_ORIGINAL_STATUSLINE:-}" ]; then
  printf "%s" "$input" | bash -lc "$CODEX_CREDITS_ORIGINAL_STATUSLINE" || true
fi
""")
wrapper_path.chmod(0o755)

if wrapper_command_prefix in current_command:
    print("Claude statusLine capture is already installed.")
else:
    command = shlex.quote(str(wrapper_path))
    if current_command:
        command = f"CODEX_CREDITS_ORIGINAL_STATUSLINE={shlex.quote(current_command)} {command}"

    settings["statusLine"] = {
        "type": "command",
        "command": command,
        "refreshInterval": current.get("refreshInterval", 30),
    }

    settings_path.write_text(json.dumps(settings, indent=2) + "\n")
    print(f"Installed Claude statusLine capture at {wrapper_path}")
PY
