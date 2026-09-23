# Repository agent instructions

## ISO testing location

- Always place completed ISOs for testing in `/data/pxe/iso`.
- Build in a unique task-specific staging directory, then copy the completed
  ISO and its SHA-256 checksum into `/data/pxe/iso`. Preserve existing images
  unless their replacement or removal is explicitly requested.
- After adding, replacing, or removing a testing ISO, refresh iVentoy's image
  list before handoff. Finish copying and verifying the checksum first; keep
  incomplete ISOs outside the served ISO tree. Use ASCII filenames without
  spaces and permissions that allow iVentoy to read the files.
- Prefer **ISO Management → Refresh** at `http://10.10.0.7:26000/`.
  On `thebeast`, the equivalent requests below were verified with iVentoy
  1.0.41. They use the installed UI's internal API, so recheck
  `http://127.0.0.1:26000/vtoy_image.html` after an iVentoy upgrade:

  ```bash
  curl --fail-with-body --silent --show-error --max-time 30 \
    -H 'Content-Type: application/json' \
    -d '{"method":"refresh_img_list"}' http://127.0.0.1:26000/iventoy/json
  curl --fail-with-body --silent --show-error --max-time 10 \
    -H 'Content-Type: application/json' \
    -d '{"method":"query_status"}' http://127.0.0.1:26000/iventoy/json
  curl --fail-with-body --silent --show-error --max-time 10 \
    -H 'Content-Type: application/json' \
    -d '{"method":"get_img_tree"}' http://127.0.0.1:26000/iventoy/json
  ```

- Require `result: success` from refresh; HTTP success alone is insufficient.
  If busy, wait for the current operation before retrying. Poll `query_status`
  until refresh completes, require PXE status `running`, and verify the
  expected filename in `get_img_tree` (and absence of any removed filename).
  Also check `systemctl is-active iventoy.service`.
- Refresh normally keeps the service running. If it fails or leaves stale
  entries/counts, use `sudo systemctl restart iventoy.service` only when no
  PXE boots/installations are in progress, then repeat the status/list checks.
  Use systemd rather than launching a second `iventoy.sh` process. The unit's
  `-R start` restores PXE with its saved configuration; see
  [upstream startup documentation](https://www.iventoy.com/en/doc_start.html).
  Local deployment details are in `/data/pxe/README.md`.

## Build and test artifact cleanup

- Clean up disposable artifacts created during your task before final handoff,
  including failed/retried image builds, test ISOs, VM disks, extracted root
  filesystems, temporary logs, and screenshots. This includes outputs outside
  the checkout, especially `~/.local/share/cybexos/images/`.
- Use a unique task-specific output directory and track what you create.
  Arrange cleanup with traps or `finally` blocks where practical so failures
  and interruptions also clean up. Stop task-owned VMs/processes and unmount
  task-owned mounts before removing their files.
- Retain only requested deliverables and artifacts still needed for review or
  unresolved diagnostics. Remove intermediate and superseded attempts; record
  useful findings in repository documentation instead of retaining large
  images solely as evidence. Report any retained artifacts with their paths,
  sizes, and reason for keeping them in the final handoff.
- Delete only artifacts you created or have verified are disposable and within
  the user's authorized cleanup scope. Do not infer that another task's files
  are stale from their name or age alone. Never blanket-delete
  `~/.local/share/cybexos`: it can also contain active releases, runtime
  configuration, user themes/plugins, and persistent data.
- Verify cleanup at the end of the task by checking the output directories
  and their disk usage. Do not leave orphaned build/test processes or mounts.

## Live Quickshell testing

- Keep exactly one live Quickshell menubar. The normal live instance is the
  process owned by `quickshell.service`; never leave a source-tree `qs -d` or
  `qs -p` process running beside it.
- At the start and end of every live shell test, automatically compare
  `systemctl --user show quickshell.service -p MainPID --value` with every PID
  returned by `pgrep -x qs`. Inspect each extra PID's command line and cgroup,
  then terminate only confirmed unmanaged/developer instances. Never use a
  blanket `pkill qs`.
- Prefer deploying the configuration and testing through
  `quickshell.service`. If a direct source-tree `qs -d -p ...` session is
  necessary, stop `quickshell.service` first and arrange cleanup that always
  terminates the developer process and restores the service, including when
  the test fails or is interrupted.
- A live test is not complete until `quickshell.service` is active, its
  `MainPID` is the sole remaining `qs` PID, and the current invocation's
  journal has been checked for QML errors.
