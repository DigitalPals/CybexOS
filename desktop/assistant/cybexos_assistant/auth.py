"""Ask the agents about sign-in without reading or copying their credentials."""

from __future__ import annotations

import asyncio
import contextlib

from .protocol import stop_process


STATUS_ARGS = {"claude": ["auth", "status"], "codex": ["login", "status"]}
LOGIN_ARGS = {"claude": ["auth", "login"], "codex": ["login"]}
STATUS_TIMEOUT = 8.0


async def status(agent, executable, home, env):
    """Both CLIs document 0 for signed in and 1 for signed out.

    Discard their output: it can identify the account and does not belong in
    the socket, persisted assistant state or journal. No model is invoked.
    """
    process = None
    try:
        process = await asyncio.create_subprocess_exec(
            executable, *STATUS_ARGS[agent], cwd=home, env=env,
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL, start_new_session=True)
        code = await asyncio.wait_for(process.wait(), STATUS_TIMEOUT)
        return "ready" if code == 0 else "required" if code == 1 else "unknown"
    except (OSError, asyncio.TimeoutError):
        return "unknown"
    finally:
        if process is not None and process.returncode is None:
            with contextlib.suppress(Exception):
                await stop_process(process)
