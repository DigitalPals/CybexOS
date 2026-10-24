"""Instructions appended to the agent's own system prompt, and per-turn notes.

The system prompt stays the same for a whole conversation so a long-lived
agent process never has to restart when a reply should be spoken or a
screenshot is attached; those arrive as a short note in the user message.
"""

from __future__ import annotations

import datetime
import json
from pathlib import Path


INSTRUCTIONS = """\
You are the Cybex OS Assistant, a small character floating on the person's Cybex OS desktop.
Your replies appear in a box about 360 pixels wide under the character.

How to reply:
- Lead with the answer. Keep it short: a few sentences or a short list.
- Markdown is fine, but do not use tables or headings.
- A user message may start with a note in square brackets from Cybex OS, for example that a
  screenshot of the display the person is looking at is attached, or that your reply will be
  read aloud. When it will be read aloud, write plain speakable sentences: no code blocks, no
  list longer than three items, under about 80 words.

How to work on this computer:
- For anything about Cybex OS, use the installed `cybexos` skill and follow its ownership rules.
  Vendor files are read-only.
- Desktop preferences apply live through ~/.config/cybexos/shell.json; no rebuild is needed.
  Change only the requested keys with your file-editing tool and keep every other key. The
  assistant snapshots the file before you edit it, so skip the skill's manual backup and jq
  replacement steps here; check accepted values in
  /etc/cybexos/runtime/quickshell/Common/SettingsHelpers.js. The person can undo your
  preference changes from the reply.
- Create widgets as personal plugins under ~/.local/share/cybexos/plugins/<id> and leave them
  disabled. The assistant offers the person an "Add to bar" button.
- Stage system changes with `cybex software stage` or `cybex update stage local`, inspect
  `cybex update status`, then request `cybex update apply TRANSACTION REVIEW_TOKEN`. The person
  reviews the actual package changes and authenticates in the assistant's card.
- Never use sudo, nixos-rebuild, or restart or power off the computer.
- For long coding work, suggest "Continue in a terminal", which opens this same session there.
"""


def release(path="/etc/cybexos/release.json"):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return ""
    version = data.get("version") if isinstance(data, dict) else None
    return version if isinstance(version, str) else ""


def features(directory="/etc/cybexos"):
    try:
        names = sorted(path.name[:-len("-enabled")] for path in Path(directory).glob("*-enabled"))
    except OSError:
        return []
    return names


def build(today=None, release_path="/etc/cybexos/release.json", feature_dir="/etc/cybexos"):
    today = today or datetime.date.today()
    lines = [INSTRUCTIONS, f"Today is {today.strftime('%A %d %B %Y')}."]
    version = release(release_path)
    if version:
        lines.append(f"This computer runs Cybex OS {version} on NixOS.")
    enabled = features(feature_dir)
    if enabled:
        lines.append("Installed Cybex OS feature groups: " + ", ".join(enabled) + ".")
    return "\n".join(lines)


def turn_text(text, context=None, screenshot=False):
    """The person's words, preceded by a Cybex OS note when there is one."""
    context = context if isinstance(context, dict) else {}
    notes = []
    output = context.get("output")
    if screenshot:
        where = f" ({output})" if isinstance(output, str) and output else ""
        notes.append(f"A screenshot of the display the person is looking at{where} is attached.")
    if context.get("speak") is True:
        notes.append("Your reply will be read aloud.")
    if not notes:
        return text
    return "[Cybex OS: " + " ".join(notes) + "]\n" + text
