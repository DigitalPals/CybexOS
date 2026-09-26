# Remote Server widget

Add **Remote Server** from Settings → Menubar → Widgets, then open its options.
Set **SSH host** to an existing SSH alias or `user@hostname`, and optionally set
a display name. For example: `john@10.10.0.7`, **The Beast**. These are personal
settings, not distribution defaults; new installations leave the widget disabled
and its host empty.

The default menubar statistic is CPU utilization. Options include load average,
memory used percent/bytes or available bytes, filesystem used percent/free bytes,
network receive/transmit rate, and the hottest reported temperature. The server
label can be hidden or compacted away on a crowded bar. Select a mount point or
interface in the options; interface buttons in the dashboard also pin that choice.
Automatic networking prefers the default route, then the busiest interface with
an address. It never sums bridges, bonds and members together.

Click the widget for CPU/memory histories, per-core activity, 1/5/15-minute load,
memory/swap capacities, local filesystems, network traffic and temperatures.
Large filesystem, interface and sensor lists expand on demand. The dashboard
scrolls within the output's available height. Missing sensors and first-sample
rates are unavailable, never zero. Disconnections retain explicitly stale values
and the time since the last successful sample.

## Connection requirements

- Linux with readable `/proc` and Python **3.9+** on the server.
- OpenSSH and Python 3 on the desktop. GNU `df` provides local filesystem stats;
  `ip` provides optional addresses/default-route discovery on the server.
- Working noninteractive SSH key/agent authentication. First connect in a
  terminal, for example `ssh john@10.10.0.7`, to verify its host key. Unknown or
  changed keys are rejected; the widget never accepts them automatically.
- Configure ports, identities and jump hosts in `~/.ssh/config`. The host field
  accepts a destination, not SSH options or a shell command.

No root access, remote installation, remote file writes or remote service is
needed. Temperature sensors depend on the host's drivers and permissions.
Physical DIMM type/speed, SMART health and privileged hardware information are
outside the current collector. Network filesystems and temporary/container
overlay mounts are excluded from capacity collection.

## Implementation and lifecycle

`Common/RemoteServer.qml` owns a single `Process` for the whole shell, independent
of monitor count. `scripts/remote-server.py` validates the destination and execs
SSH, sending the self-contained `remote_server_probe.py` as a quoted Python
program. One persistent SSH channel streams newline-delimited JSON. Its stdin
accepts cadence/refresh messages, and EOF terminates the probe. The connection
does not create a background SSH master or forward an agent/ports.

The default interval is five seconds; opening the dashboard or its settings
claims two-second sampling. Closing the last view returns to the configured
interval. Disabling the widget and closing its views stops the connection.
CPU and network rates use counter deltas over actual monotonic elapsed time,
with unknown rates on initial/reset samples. Memory usage uses `MemAvailable`,
not `MemFree`; filesystem free space is what an unprivileged user can use.
Hardware details, addresses and filesystems refresh every minute, or on Refresh;
optional `df`/`ip` commands have bounded execution time.

History stays in memory (up to ten minutes/300 points) and resets on host change,
reboot or a long sampling gap. Reconnection backs off from five to sixty seconds.
A heartbeat timeout catches a stalled stream. Host changes discard old data and
ignore the previous connection's late output. SSH failures appear in the view.

Read-only diagnostics and manual refresh use the normal runtime IPC entrypoint:

```sh
cybexos-runtime ipc remoteServer status
cybexos-runtime ipc remoteServer refresh
cybexos-runtime ipc remoteServer configure
cybexos-runtime ipc popouts open remote
```

Tests cover counter resets, memory semantics, cache lifetime, transport quoting,
SSH restrictions, stream cadence/EOF, malformed samples, interface selection,
metric formatting, history bounds and settings migration. Run `./tests/run`.
For live checks, use `tests/lib/quickshell-live` begin/end and the managed service.
