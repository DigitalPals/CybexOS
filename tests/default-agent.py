#!/usr/bin/env python3
"""Runtime contracts for the user-scoped default AI agent dispatcher."""

from __future__ import annotations

import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "assets/scripts/cybexos-agent"


def executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


def fake_capture(path: Path) -> None:
    executable(
        path,
        """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

Path(os.environ["AGENT_LOG"]).write_text(json.dumps({
    "program": Path(sys.argv[0]).name,
    "argv": sys.argv[1:],
    "cwd": os.getcwd(),
}))
""",
    )


def test_environment(home: Path, binaries: Path, log: Path) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / "xdg-config"),
            "PATH": f"{binaries}:/usr/bin:/bin",
            "AGENT_LOG": str(log),
        }
    )
    return environment


def run_launcher(
    environment: dict[str, str], *arguments: str, cwd: Path
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(LAUNCHER), *arguments],
        cwd=cwd,
        env=environment,
        text=True,
        capture_output=True,
    )


def captured(log: Path) -> dict:
    return json.loads(log.read_text())


def run_picker_in_pty(environment: dict[str, str], cwd: Path) -> tuple[int, str]:
    pid, descriptor = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execve(
            "/usr/bin/bash",
            ["bash", str(LAUNCHER), "--pick"],
            environment,
        )

    output = bytearray()
    while True:
        try:
            chunk = os.read(descriptor, 4096)
        except OSError:
            break
        if not chunk:
            break
        output.extend(chunk)
    os.close(descriptor)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), output.decode(errors="replace")


def main() -> None:
    assert LAUNCHER.is_file()

    with tempfile.TemporaryDirectory(prefix="cybexos-default-agent.") as temporary:
        root = Path(temporary)
        home = root / "home"
        binaries = root / "bin"
        working = root / "project"
        log = root / "invocation.json"
        home.mkdir()
        (home / "Code").mkdir()
        binaries.mkdir()
        working.mkdir()

        for name in ("opencode", "claude", "codex", "kitty"):
            fake_capture(binaries / name)
        executable(binaries / "cybex", "#!/usr/bin/env bash\nexit 99\n")

        environment = test_environment(home, binaries, log)
        preference = home / "xdg-config/cybexos/defaults/agent"

        result = run_launcher(environment, "set", "opencode", cwd=working)
        assert result.returncode == 0, result.stderr
        assert preference.read_text() == "opencode\n"
        assert preference.stat().st_mode & 0o777 == 0o600

        result = run_launcher(environment, "get", cwd=working)
        assert result.returncode == 0
        assert result.stdout == "opencode\n"

        result = run_launcher(environment, cwd=working)
        assert result.returncode == 0, result.stderr
        assert captured(log) == {"program": "opencode", "argv": [], "cwd": str(working)}

        sentinel = root / "prompt-was-executed"
        prompt = f'quote " and $(touch {sentinel})\nsecond line'
        result = run_launcher(environment, "prompt", prompt, cwd=working)
        assert result.returncode == 0, result.stderr
        assert captured(log) == {
            "program": "opencode",
            "argv": ["--prompt", prompt],
            "cwd": str(working),
        }
        assert not sentinel.exists(), "prompt text was evaluated by a shell"

        result = run_launcher(environment, "set", "claude", cwd=working)
        assert result.returncode == 0, result.stderr
        result = run_launcher(environment, "prompt", "review", "carefully", cwd=working)
        assert result.returncode == 0, result.stderr
        assert captured(log)["argv"] == ["--", "review carefully"]

        result = run_launcher(environment, "set", "codex", cwd=working)
        assert result.returncode == 0, result.stderr
        result = run_launcher(environment, "prompt", "explain this", cwd=working)
        assert result.returncode == 0, result.stderr
        assert captured(log)["argv"] == ["--", "explain this"]
        result = run_launcher(environment, cwd=working)
        assert result.returncode == 0, result.stderr
        assert captured(log)["argv"] == [], "interactive launch added permission flags"

        result = run_launcher(environment, "set", "not-an-agent", cwd=working)
        assert result.returncode == 2
        assert preference.read_text() == "codex\n", "failed selection replaced the default"

        (binaries / "claude").rename(binaries / "claude.disabled")
        result = run_launcher(environment, "set", "claude", cwd=working)
        assert result.returncode == 127
        assert preference.read_text() == "codex\n", "missing agent replaced the default"
        (binaries / "claude.disabled").rename(binaries / "claude")

        result = run_launcher(environment, "list", cwd=working)
        assert result.returncode == 0
        assert "* codex    installed" in result.stdout
        assert "  opencode installed" in result.stdout

        result = run_launcher(environment, "--window", "--pick", cwd=working)
        assert result.returncode == 0, result.stderr
        window = captured(log)
        assert window["program"] == "kitty"
        assert window["argv"] == [
            "--class",
            "cybexos-agent",
            "--directory",
            str(home / "Code"),
            "-e",
            str(binaries / "cybex"),
            "agent",
            "--window-child",
            "--pick",
        ]

        result = run_launcher(environment, "unset", cwd=working)
        assert result.returncode == 0
        assert not preference.exists()
        result = run_launcher(environment, cwd=working)
        assert result.returncode == 1
        assert "run 'cybex agent set' in a terminal" in result.stderr

        preference.parent.mkdir(parents=True, exist_ok=True)
        preference.write_text("codex\nclaude\n")
        result = run_launcher(environment, "get", cwd=working)
        assert result.returncode == 1
        assert "preference" in result.stderr
        result = run_launcher(environment, "set", "opencode", cwd=working)
        assert result.returncode == 0
        assert preference.read_text() == "opencode\n"

        executable(
            binaries / "fzf",
            """#!/usr/bin/env python3
import sys

for line in sys.stdin:
    if line.startswith("codex\\t"):
        sys.stdout.write(line)
        break
""",
        )
        status, output = run_picker_in_pty(environment, working)
        assert status == 0, output
        assert preference.read_text() == "codex\n"
        assert captured(log) == {"program": "codex", "argv": [], "cwd": str(working)}

    print("default AI agent selection, launch, and prompt routing are safe")


if __name__ == "__main__":
    main()
