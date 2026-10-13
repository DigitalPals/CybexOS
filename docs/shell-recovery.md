# Shell crash recovery

The managed Quickshell service records failed invocations without supervising a
second process. The launcher replaces itself with `qs`, so the service MainPID
remains the only shell process. Three failed invocations within two minutes
select the standalone recovery configuration on the next start. Successful
service stops, deliberate restarts, a long healthy run, and a new boot reset the
failure counter. A late stop notification cannot override a recovery choice.

Recovery uses `quickshell/safe-mode/shell.qml`. It provides a bar on every output,
a clock, a terminal button, and **Retry desktop**. Super+Space opens a terminal.
It imports no normal settings, theme, plugins or connected integrations, so a
broken widget or personal setting cannot prevent the recovery UI from loading.
The minimal desktop does not provide the normal notification or authentication
interfaces. User settings and plugin enablement are never rewritten.

```sh
cybex shell status             # JSON status, last exit and selected runtime
cybex shell safe               # enter recovery and restart the managed service
cybex plugin list              # inspect installed plugins while in recovery
cybex plugin disable PLUGIN_ID # disable an identified broken plugin normally
cybex shell recover            # clear the crash counter and retry the full shell
```

**Retry desktop** performs the same action as `cybex shell recover`. If the
problem persists, the next three failures return to recovery. If it began in a
development checkout, `cybex dev disable` also remains available. Recovery does
not guess which plugin caused an exit: the status record and current service
journal support diagnosis without discarding working settings.

The private, atomic state record is
`$XDG_STATE_HOME/cybexos/shell-recovery.json` (normally
`~/.local/state/cybexos/shell-recovery.json`). It stores lifecycle metadata only.
Malformed state chooses recovery. Explicit recovery remains active across
reboots until the user retries; stale failure counts do not cross boots. Older
runtimes without this mechanism retain their normal launch behavior on rollback.

`tests/shell-recovery.py` exercises crash accounting, stale stop callbacks,
normal restarts, boot boundaries, recovery commands, malformed state and exact
preservation of shell/plugin configuration. It does not launch a live shell.
