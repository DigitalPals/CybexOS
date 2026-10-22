# Contributing

Read [AGENTS.md](AGENTS.md). NixOS is the only operating-system implementation.
Develop vendor behavior in `nix/modules`, `lifecycle`, `installer`, `desktop`,
and `hardware`. Keep personal declarations out of vendor code.

Use `nix develop` and `tests/run`, then `nix flake check --no-build` and relevant
Nix builds/VM tests. Source fixtures must be reported separately from actual
installation and update tests. `scripts/qualify-installations` owns disposable
VMs/disks and exercises the actual installer and updater, with evidence tied to
source content. Hardware claims require representative physical machines.

Every product change covers the shared module and both installation entry points.
Keep plugin API 1 and the supported Omarchy adapter functional. Runtime preferences
must preserve unknown fields and explicit choices. Never fix an update by removing
personal modules, resetting settings or silently disabling an extension.

Use isolated environments. Do not deploy a development shell onto the running
workstation without authorization. Any live Quickshell test must use
`tests/lib/quickshell-live`, including its final PID/service/journal checks.

Release workflows are protected operations and require complete same-revision
qualification, operator-owned signing keys and immutable GitHub Releases. See
[release operations](docs/releasing.md).
