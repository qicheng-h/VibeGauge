#!/bin/zsh
set -euo pipefail

python3 - <<'PY'
import json
import shlex
from pathlib import Path

home = Path.home()
settings_path = home / ".claude" / "settings.json"
wrapper_path = home / ".claude" / "codex-credits-statusline.sh"
original_path = home / ".claude" / "codex-credits-original-statusline.txt"

settings = {}
if settings_path.exists():
    backup_path = settings_path.with_suffix(".json.codex-credits-backup")
    if not backup_path.exists():
        backup_path.write_text(settings_path.read_text())
    settings = json.loads(settings_path.read_text())

current = settings.get("statusLine", {})
current_command = current.get("command", "")
wrapper_command_prefix = str(wrapper_path)

original_command = ""
if wrapper_command_prefix in current_command:
    try:
        for token in shlex.split(current_command):
            if token.startswith("CODEX_CREDITS_ORIGINAL_STATUSLINE="):
                original_command = token.split("=", 1)[1]
                break
    except ValueError:
        original_command = ""
else:
    original_command = current_command

if original_command:
    original_path.write_text(original_command)

wrapper_path.write_text("""#!/bin/bash
set -euo pipefail

input=$(cat)
state="${HOME}/.claude/codex-credits-status.json"
tmp="${state}.tmp"
original="${HOME}/.claude/codex-credits-original-statusline.txt"

printf "%s" "$input" > "$tmp"
mv "$tmp" "$state"

if [ -s "$original" ]; then
  printf "%s" "$input" | bash -lc "$(cat "$original")" || true
fi
""")
wrapper_path.chmod(0o755)

settings["statusLine"] = {
    "type": "command",
    "command": shlex.quote(str(wrapper_path)),
    "refreshInterval": current.get("refreshInterval", 30),
}

settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"Installed Claude statusLine capture at {wrapper_path}")
if original_command:
    print(f"Preserved original statusLine at {original_path}")
PY
