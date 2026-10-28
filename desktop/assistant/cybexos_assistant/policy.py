"""What the agent may do without asking, and the file snapshots behind Undo.

Every permission prompt from either agent reaches decide_tool(),
decide_command() or decide_edit(). They are pure apart from reading the
lifecycle status for an apply card, so the table in docs/assistant.md is
tested here rather than through a model.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shlex
import tempfile


READ_ONLY_TOOLS = frozenset({
    "Read", "Glob", "Grep", "LS", "NotebookRead", "WebSearch", "WebFetch",
    "TodoWrite", "Task", "Agent", "Skill", "ToolSearch", "BashOutput",
    "KillShell", "KillBash", "ExitPlanMode",
})
EDIT_TOOLS = {"Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path",
              "NotebookEdit": "notebook_path"}
VENDOR_PREFIXES = ("/nix/store", "/etc/cybexos", "/run/current-system", "/etc/static")
PERSONAL_PREFIXES = (".config/cybexos", ".local/share/cybexos/plugins")
TRUSTED_BIN = ("/run/current-system/sw/bin/", "/etc/profiles/per-user/", "/usr/bin/", "/bin/")

VENDOR_MESSAGE = ("Vendor files are read-only. Personal changes belong in ~/.config/cybexos, "
                  "a personal plugin under ~/.local/share/cybexos/plugins, or /etc/nixos/local "
                  "staged with cybex update stage local.")
ADMIN_MESSAGE = ("The assistant does not run commands as administrator. Stage system changes "
                 "with cybex software stage or cybex update stage local; the person reviews and "
                 "authenticates the staged change.")
REBUILD_MESSAGE = ("Cybex OS applies only reviewed changes. Use cybex update stage local, then request "
                   "cybex update apply TRANSACTION REVIEW_TOKEN instead of nixos-rebuild.")
POWER_MESSAGE = ("The assistant never restarts, suspends or powers off the computer. Tell the "
                 "person what is needed so they can do it when they are ready.")
RECOVERY_MESSAGE = ("Rollback, boot confirmation and retrying a failed deployment are the "
                    "person's decision. Explain the command instead of running it.")

ADMIN_COMMANDS = {"sudo", "doas", "pkexec", "su", "run0"}
POWER_COMMANDS = {"reboot", "poweroff", "shutdown", "halt", "kexec"}
POWER_VERBS = {"reboot", "poweroff", "halt", "suspend", "hibernate", "hybrid-sleep",
               "suspend-then-hibernate", "kexec", "soft-reboot"}

SIMPLE_READ = {
    "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg", "fd", "find", "jq", "yq",
    "stat", "file", "wc", "which", "type", "uname", "id", "whoami", "date", "df", "du",
    "free", "lsblk", "lscpu", "lspci", "lsusb", "uptime", "readlink",
    "realpath", "basename", "dirname", "sort", "uniq", "cut", "tr", "column", "diff",
    "sha256sum", "md5sum", "pwd", "echo", "printf", "tree", "hostname", "groups",
    "locale", "nproc", "command", "cd", "test", "true",
}
FIND_ACTIONS = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0",
                "-fprintf", "-fls"}
GIT_READ = {"status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe",
            "shortlog"}
HYPR_READ = {"monitors", "clients", "workspaces", "activeworkspace", "activewindow",
             "devices", "binds", "layers", "getoption", "version", "systeminfo",
             "cursorpos", "splash", "workspacerules", "layouts", "animations", "globalshortcuts",
             "configerrors"}
SYSTEMCTL_READ = {"status", "is-active", "is-enabled", "is-failed", "list-units",
                  "list-timers", "list-unit-files", "list-sockets", "list-dependencies",
                  "show", "cat", "show-environment"}
SYSTEMCTL_VALUE_OPTIONS = {"-t", "--type", "--state", "-n", "--lines", "-p", "--property",
                           "-o", "--output"}
JOURNAL_WRITES = ("--vacuum", "--rotate", "--flush", "--sync", "--relinquish-var",
                  "--smart-relinquish-var", "--setup-keys", "--update-catalog")
STAGE_SCOPES = {"local", "upstream", "cybexos", "both"}
SHELLS = {"bash", "sh", "zsh", "dash"}
# Redirections that cannot write anything a person would miss.
SAFE_REDIRECT = re.compile(r"(?<!\S)(?:[12]?>\s*/dev/null|2>&1)(?!\S)")
HOME_VARIABLE = re.compile(r"^\$(?:HOME|\{HOME\})(?:/|$)")
OPERATORS = set(";&|<>()")
MAX_DIFF = 6000
MAX_CHANGES = 16000


class Decision:
    """allow, deny or ask; ask carries the card the person sees."""

    def __init__(self, action, message="", card=None, step="", paths=(), key=None):
        self.action = action
        self.message = message
        self.card = card
        self.step = step
        self.paths = list(paths)
        # What an "always" answer remembers for the rest of the conversation.
        self.key = key

    def __repr__(self):
        return f"Decision({self.action!r}, {self.message or self.step or ''!r})"


def allow(step="", paths=()):
    return Decision("allow", step=step, paths=paths)


def deny(message):
    return Decision("deny", message=message)


def ask(card, key=None, paths=()):
    return Decision("ask", card=card, key=key, paths=paths)


def clip(text, limit):
    text = str(text)
    return text if len(text) <= limit else text[:limit - 1] + "…"


# ---- paths -----------------------------------------------------------------

def expand(path, home):
    path = str(path)
    if path == "~" or path.startswith("~/"):
        path = str(home) + path[1:]
    if not os.path.isabs(path):
        path = os.path.join(str(home), path)
    return os.path.normpath(path)


def under(path, prefix):
    prefix = prefix.rstrip("/")
    return path == prefix or path.startswith(prefix + "/")


def display(path, home):
    home = str(home).rstrip("/")
    return "~" + path[len(home):] if under(path, home) else path


def vendor(path):
    real = os.path.realpath(path)
    return any(under(candidate, prefix) for candidate in (path, real) for prefix in VENDOR_PREFIXES)


def personal(path, home):
    # The write lands where the path resolves: a link out of the personal
    # directories (a dotfile manager's link to ~/.bashrc) is an ordinary edit.
    def inside(candidate, base):
        return any(under(candidate, os.path.join(base, prefix)) for prefix in PERSONAL_PREFIXES)
    return inside(path, str(home)) and inside(os.path.realpath(path), os.path.realpath(str(home)))


def decide_edit(paths, home, diff="", reason=""):
    """One edit (Claude) or one patch of several files (Codex)."""
    expanded = [expand(path, home) for path in paths if isinstance(path, str) and path]
    if not expanded:
        return ask({"kind": "edit", "title": "Edit a file", "detail": reason or "", "diff": clip(diff, MAX_DIFF)})
    if any(vendor(path) for path in expanded):
        return deny(VENDOR_MESSAGE)
    if all(personal(path, home) for path in expanded):
        return allow(paths=expanded)
    shown = [display(path, home) for path in expanded]
    title = ("Edit " + os.path.basename(expanded[0])) if len(expanded) == 1 else f"Edit {len(expanded)} files"
    card = {"kind": "edit", "title": title, "detail": reason or "\n".join(shown[:8]),
            "path": shown[0], "diff": clip(diff, MAX_DIFF)}
    return ask(card, key=("edit", tuple(sorted(expanded))), paths=expanded)


def edit_preview(tool, tool_input):
    def lines(prefix, text):
        return "\n".join(prefix + line for line in str(text).splitlines()[:40])
    if tool == "Edit":
        return lines("- ", tool_input.get("old_string", "")) + "\n" + lines("+ ", tool_input.get("new_string", ""))
    if tool == "MultiEdit":
        parts = []
        for edit in (tool_input.get("edits") or [])[:6]:
            if isinstance(edit, dict):
                parts.append(lines("- ", edit.get("old_string", "")) + "\n" + lines("+ ", edit.get("new_string", "")))
        return "\n…\n".join(parts)
    if tool == "Write":
        return lines("+ ", tool_input.get("content", ""))
    if tool == "NotebookEdit":
        return lines("+ ", tool_input.get("new_source", ""))
    return ""


# ---- commands --------------------------------------------------------------

def tokens(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def operator(token):
    return bool(token) and all(character in OPERATORS for character in token)


def segments(command):
    """Every command word list in a command line, for refusal; None if unparsable."""
    try:
        words = tokens(command.replace("`", " ` ").replace("$(", " $( "))
    except ValueError:
        return None
    found, current = [], []
    for token in words:
        if operator(token) or token in ("`", "$("):
            if current:
                found.append(current)
            current = []
        else:
            current.append(token)
    if current:
        found.append(current)
    return found


def command_list(command):
    """Pipelines joined by ;, && or ||, each a list of stages; None otherwise.

    Anything else a shell would interpret (redirection, background jobs,
    subshells, substitution) makes the line not simple.
    """
    if any(character in command for character in "`\n\r") or "$(" in command:
        return None
    try:
        words = tokens(SAFE_REDIRECT.sub(" ", command))
    except ValueError:
        return None
    pipelines = [[[]]]
    for token in words:
        if token == "|":
            pipelines[-1].append([])
        elif token in (";", "&&", "||"):
            pipelines.append([[]])
        elif operator(token):
            return None
        else:
            pipelines[-1][-1].append(token)
    if pipelines[-1] == [[]] and len(pipelines) > 1:
        pipelines.pop()
    return pipelines if all(all(stages) for stages in pipelines) else None


def program(argv):
    """The executable's name, or "" for a path outside the system profile."""
    name = argv[0]
    if "/" in name:
        if not name.startswith(TRUSTED_BIN):
            return ""
        name = os.path.basename(name)
    return name


def refusal(argv):
    words = list(argv)
    while words and "=" in words[0] and not words[0].startswith("="):
        words.pop(0)
    if not words:
        return ""
    name = os.path.basename(words[0])
    if name == "env":
        return refusal(words[1:])
    if name in ADMIN_COMMANDS:
        return ADMIN_MESSAGE
    if name == "nixos-rebuild":
        return REBUILD_MESSAGE
    if name in POWER_COMMANDS:
        return POWER_MESSAGE
    verbs = [word for word in words[1:] if not word.startswith("-")]
    if name in ("systemctl", "loginctl") and verbs and verbs[0] in POWER_VERBS:
        return POWER_MESSAGE
    if name == "cybex" and verbs[:1] == ["update"] and len(verbs) > 1 \
            and verbs[1] in ("rollback", "confirm", "retry-failed"):
        return RECOVERY_MESSAGE
    return ""


def short_flags(args, letters):
    return any(arg.startswith("-") and not arg.startswith("--") and any(letter in arg[1:] for letter in letters)
               for arg in args)


def git_read_only(args):
    args = list(args)
    while args and args[0] in ("-C", "--no-pager", "-P"):
        args = args[2:] if args[0] == "-C" else args[1:]
    if not args or args[0].startswith("-"):
        return False
    verb, rest = args[0], args[1:]
    if any(arg.startswith("--output") or arg in ("--ext-diff", "-c") for arg in rest):
        return False
    if verb in GIT_READ:
        return True
    if verb == "branch":
        return all(arg in ("-a", "-r", "-v", "-vv", "--list", "--all", "--remotes", "--show-current") for arg in rest)
    if verb == "remote":
        return all(arg in ("-v", "--verbose") for arg in rest)
    return False


def hyprctl_read_only(args):
    args = list(args)
    while args and args[0].startswith("-"):
        if args[0] in ("-j", "--json"):
            args = args[1:]
        elif args[0] in ("-i", "--instance") and len(args) > 1:
            args = args[2:]
        else:
            return False
    return bool(args) and args[0] in HYPR_READ


def systemctl_read_only(args):
    args = list(args)
    while args and args[0].startswith("-"):
        option = args[0]
        if option in ("-H", "--host", "-M", "--machine") or option.startswith(("--host=", "--machine=")):
            return False
        args = args[2:] if option in SYSTEMCTL_VALUE_OPTIONS else args[1:]
    return bool(args) and args[0] in SYSTEMCTL_READ


def cybex_read_only(args):
    verbs = list(args)
    if verbs in (["version"], ["doctor"], ["doctor", "--json"]):
        return True
    head = verbs[:2]
    return (head[:1] == ["update"] and head[1:] in (["status"], ["check"], ["history"], ["log"])
            or head[:1] == ["software"] and head[1:] in (["list"], ["search"], ["request"])
            or head in (["plugin", "list"], ["shell", "status"])
            or head[:1] == ["agent"] and head[1:] in (["list"], ["get"])
            or head[:1] == ["maintenance"] and head[1:] in (["status"], ["request"])
            or head[:1] == ["assistant"] and head[1:] == ["status"])


def read_only(argv):
    name = program(argv)
    args = argv[1:]
    if not name or any("$" in word and not HOME_VARIABLE.match(word) for word in argv):
        return False
    if name in SIMPLE_READ:
        if name == "find":
            return not any(arg in FIND_ACTIONS for arg in args)
        if name == "fd":
            return not any(arg in ("--exec", "--exec-batch") or arg.startswith(("--exec=", "--exec-batch="))
                           for arg in args) and not short_flags(args, "xX")
        if name == "rg":
            return not any(arg == "--pre" or arg.startswith("--pre=") for arg in args)
        if name == "sort":
            return not any(arg.startswith("--output") for arg in args) and not short_flags(args, "o")
        if name == "uniq":
            return len([arg for arg in args if not arg.startswith("-")]) <= 1
        if name == "tree":
            return "-o" not in args
        if name == "yq":
            return not any(arg.startswith("--inplace") for arg in args) and not short_flags(args, "i")
        if name == "date":
            return not any(arg.startswith("--set") for arg in args) and not short_flags(args, "s")
        if name == "hostname":
            return all(arg.startswith("-") for arg in args)
        if name == "command":
            return args[:1] == ["-v"]
        return True
    if name == "git":
        return git_read_only(args)
    if name == "hyprctl":
        return hyprctl_read_only(args)
    if name == "cybex":
        return cybex_read_only(args)
    if name == "systemctl":
        return systemctl_read_only(args)
    if name == "journalctl":
        return not any(arg.startswith(JOURNAL_WRITES) for arg in args)
    # Evaluation is not reading: an expression can read the environment,
    # fetch from the network and build through import-from-derivation.
    if name == "nix":
        return args == ["--version"]
    return False


def read_json(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def apply_card(command, transaction, status_path):
    status = read_json(status_path) if status_path else {}
    same = status.get("transaction") == transaction
    detail = (status.get("phase") if same else "") or \
        "Review the package changes, then authenticate as administrator to apply them."
    return {"kind": "apply", "title": "Apply the staged change", "detail": clip(detail, 400),
            "command": command, "transaction": transaction,
            "changes": clip(status.get("changes", ""), MAX_CHANGES) if same else "",
            "ready": bool(same and status.get("state") == "ready")}


def decide_command(command, home=None, status_path=None, depth=0):
    if not isinstance(command, str) or not command.strip():
        return ask({"kind": "command", "title": "Run a command", "detail": "", "command": ""})
    command = command.strip()
    for argv in segments(command) or []:
        message = refusal([word.lstrip("`$(") for word in argv])
        if message:
            return deny(message)
    pipelines = command_list(command)
    if pipelines is not None and len(pipelines) == 1 and len(pipelines[0]) == 1:
        argv = pipelines[0][0]
        name = program(argv)
        if name in SHELLS and len(argv) == 3 and argv[1] in ("-c", "-lc", "-cl", "-ec", "-ce") and depth < 3:
            inner = decide_command(argv[2], home, status_path, depth + 1)
            if inner.action != "ask":
                return inner
        if name == "cybex":
            verbs = argv[1:]
            if verbs[:2] == ["update", "stage"] and len(verbs) == 3 and verbs[2] in STAGE_SCOPES:
                return allow(step="Waiting for administrator authentication")
            if verbs[:2] == ["software", "stage"] and len(verbs) == 3:
                return allow(step="Waiting for administrator authentication")
            if verbs[:2] == ["update", "apply"] and len(verbs) == 4:
                card = apply_card(command, verbs[2], status_path)
                return ask(card, key=None)
    if pipelines is not None and all(read_only(stage) for stages in pipelines for stage in stages):
        return allow()
    card = {"kind": "command", "title": "Run a command", "detail": "", "command": clip(command, 4000)}
    return ask(card, key=("command", command))


def decide_tool(name, tool_input, home, status_path=None):
    """Claude Code's can_use_tool: one tool call and its input."""
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    if name in READ_ONLY_TOOLS:
        return allow()
    if name == "Bash":
        return decide_command(tool_input.get("command"), home, status_path)
    if name in EDIT_TOOLS:
        path = tool_input.get(EDIT_TOOLS[name])
        decision = decide_edit([path] if isinstance(path, str) else [], home, edit_preview(name, tool_input))
        return decision
    if name.startswith("mcp__"):
        parts = name.split("__")
        server, tool = (parts[1], "__".join(parts[2:])) if len(parts) > 2 else ("", name)
        title = f"Use {tool}" + (f" from {server}" if server else "")
    else:
        title = f"Use {name}"
    detail = clip(json.dumps(tool_input, ensure_ascii=False, indent=1), 1500)
    return ask({"kind": "other", "title": title, "detail": detail, "tool": name}, key=("tool", name))


# ---- undo ------------------------------------------------------------------

WATCHED = (".config/cybexos/shell.json", ".config/cybexos/displays.json", ".config/cybexos/hypr/user.lua")
MAX_SNAPSHOT = 8 * 1024 * 1024
UNSNAPSHOTTABLE = object()


def file_state(path):
    """None when absent, (bytes, mode) for a regular file, or UNSNAPSHOTTABLE."""
    try:
        status = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError:
        return UNSNAPSHOTTABLE
    if not os.path.isfile(path) or os.path.islink(path) or status.st_size > MAX_SNAPSHOT:
        return UNSNAPSHOTTABLE
    try:
        return Path(path).read_bytes(), status.st_mode & 0o7777
    except OSError:
        return UNSNAPSHOTTABLE


def content(state):
    return None if state is None else state[0]


def write_atomic(path, data, mode):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=".cybexos-assistant-", dir=directory)
    try:
        with os.fdopen(handle, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


class Snapshots:
    """Pre-images of the files one turn may change, so Undo can restore them."""

    def __init__(self, home):
        self.home = str(home)
        self.before = {}
        self.after = {}

    def begin(self):
        for relative in WATCHED:
            self.take(os.path.join(self.home, relative))

    def take(self, path):
        path = expand(path, self.home)
        if path not in self.before:
            self.before[path] = file_state(path)

    def finish(self):
        """Record post-images; returns the changed paths for display."""
        self.after = {}
        for path, before in self.before.items():
            if before is UNSNAPSHOTTABLE:
                continue
            now = file_state(path)
            if now is UNSNAPSHOTTABLE or content(now) == content(before):
                continue
            self.after[path] = now
        return [display(path, self.home) for path in sorted(self.after)]

    def undo(self):
        restored, skipped = [], []
        plugins = os.path.join(self.home, ".local/share/cybexos/plugins")
        for path, after in sorted(self.after.items()):
            shown = display(path, self.home)
            now = file_state(path)
            if now is UNSNAPSHOTTABLE or content(now) != content(after):
                skipped.append(shown)
                continue
            before = self.before[path]
            try:
                if before is None:
                    if now is not None:
                        os.unlink(path)
                    # A widget the turn created leaves no empty folders behind.
                    parent = os.path.dirname(path)
                    while under(parent, plugins) and parent != plugins:
                        try:
                            os.rmdir(parent)
                        except OSError:
                            break
                        parent = os.path.dirname(parent)
                else:
                    write_atomic(path, before[0], before[1])
            except OSError:
                skipped.append(shown)
                continue
            restored.append(shown)
        self.after = {}
        return restored, skipped


# ---- what a turn produced ---------------------------------------------------

PLUGIN_ID = re.compile(r"^[a-z0-9]+(\.[a-z0-9-]+)+$")


def plugin_manifests(home):
    root = Path(home) / ".local/share/cybexos/plugins"
    found = {}
    try:
        manifests = sorted(root.glob("*/manifest.json"))
    except OSError:
        return found
    for manifest in manifests:
        data = read_json(manifest)
        identifier = data.get("id")
        if isinstance(identifier, str) and PLUGIN_ID.fullmatch(identifier):
            name = data.get("name")
            found[identifier] = clip(name, 80) if isinstance(name, str) and name.strip() else identifier
    return found


def new_plugins(before, after):
    return [{"id": identifier, "name": after[identifier]} for identifier in sorted(after) if identifier not in before]


def staged_transaction(before, after):
    transaction = after.get("transaction")
    if after.get("state") == "ready" and isinstance(transaction, str) and transaction \
            and transaction != before.get("transaction"):
        return transaction
    return ""
