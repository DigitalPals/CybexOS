# Installer Wi-Fi, reconnection and disk safety — 2026-10-24

The tested installer flows pass after fixing Wi-Fi connection, reconnection,
keyboard focus and disk-safety defects. Both a graphical encrypted installation
with all nine application groups and a plain NVMe installation completed,
booted and passed login/password checks in disposable QEMU/KVM UEFI guests
on thebeast.
The [JSON evidence](installer-network-partitioning-2026-10-24.json) records the
exact source and image used, individual results and cleanup checks.

## Tested image

- Version: `1.0.0-beta.2`, NixOS `26.05`, x86_64.
- Base commit: `2c0c4bcab02f1432129dc2480c468813ea59a965` plus the audit fixes.
- Revision metadata: `uncommitted`; this is an unreleased working snapshot.
- Exact source NAR: `sha256-mI5CKPcHh1U8GyiiJ7wjS3IUP1OWVUauDbE/Yf7Kn88=`.
- ISO: `/data/pxe/iso/cybexos-1.0.0-beta.2-20261024-wifi-audit-v4.iso`.
- Size: **7,120,576,512 bytes (6.63 GiB)**; SHA-256 is stored alongside it in
  the `.iso.sha256` file.
- SHA-256: `5206b0bbe61c705a9897a0895f334805e18b8fa5cb6c34f29789eea458cbcdad`.

The ISO was built from a frozen source directory. All runtime fixes and tests
were in that snapshot. This report, its JSON evidence and the final testing
instructions were written afterward. No flake input was refreshed.

## Defects fixed

1. **Joining a new Wi-Fi network failed.** The installer sent `uuid: null`;
   the helper turned it into the string `"None"` and rejected it as an invalid
   profile UUID. A missing UUID now creates a new profile with the supplied
   credentials. Failed new profiles are removed.
2. **Network actions could be lost behind polling.** A bounded pending action
   now runs after the current snapshot. Background polling preserves actionable
   errors, Refresh requests a real scan, and cancellation reaps the helper and
   its subprocesses.
3. **Submitting a Wi-Fi password stranded keyboard focus.** Removing the
   focused input left Escape and Tab ineffective. Submission now restores
   focus to the surviving network panel. A rendered interaction test and real
   ISO keyboard/pointer input cover this path.
4. **Network recovery was unavailable during installation.** The network chip
   and sheet now remain usable through progress updates. Repeatable Nix lock,
   installation and archive operations can resume after connectivity returns.
   Recovery waits up to 15 minutes per outage and permits three attempts per
   operation. It never reruns partitioning or formatting. Build errors with
   working connectivity still fail normally.
5. **Mounted partitions could be invisible to the disk guard.** Requesting
   `PATH` without `NAME` made `lsblk` return flat JSON. The guard now requests
   `--tree`, sees child mounts and rejects active encryption/LVM/RAID mappings.
   Partition preparation explicitly rereads the table. The screen marks the
   disk changed immediately before disk commands, rather than at preflight.
6. **The candidate desktop check could hang.** Detached QML helpers retained
   output pipes. The check now uses a private PID namespace, exits through
   `Qt.quit()`, and requires a successful exit status. The actual staged updater
   and installed-system checks exercise it.
7. **The completion logo overlapped its heading.** Explicit image bounds keep
   the logo above the welcome message. The final ISO includes this correction;
   the actual completion screen is checked after the graphical installation.

## Network checks completed

The final ISO's own installer screen, daemon, helper, NetworkManager and
wpa_supplicant handled the connections. `mac80211_hwsim` supplied two simulated
radios. A separate guest network namespace ran hostapd, DHCP and NAT; Ethernet
was moved into that namespace, so the client could not fall back to Ethernet.
Only the access-point tools came from a read-only host-store mount.

| Check | Observed result |
| --- | --- |
| Ethernet unplug and replug | Offline detected; connection returned automatically. |
| Refresh and WPA2 scanning | Access point appeared in the installer. |
| Wrong WPA2 password through the actual GUI | Activation failed visibly; failed profile removed. |
| Correct password on the next GUI attempt | Connected; real HTTPS succeeded with `wlan0` the sole default route. |
| Access point disappears and returns | Automatic reconnection and successful HTTPS. |
| NetworkManager restarts | Saved profile reconnected automatically; HTTPS passed. |
| WPA3 SAE with mandatory protected management frames | Authentication and HTTPS passed through the installer helper. |
| Network panel during installation | Real pointer opened it at stage 4; it survived background updates; Escape restored progress. |
| Network setup without installation | `diskTouched` stayed false; both installer services remained active. |

Both WPA2 passwords were typed through the real Slint screen using QMP keyboard
and pointer events. WPA3 used the same daemon's network-connect interface.
The first extended WPA3 harness restarted hostapd before its previous process
finished exiting. Waiting for that process to exit fixed the test setup; the
entire final network run then passed.

A separate real Nix transfer was deliberately started with the guest's network
link down. The production recovery function emitted **Connection interrupted**,
waited for the link, emitted **Connection restored. Resuming installation**,
and completed on attempt two. This check ran alongside the actual staged
updater, using this exact source.

## Installation and partitioning

The final plain NVMe test completed installation onto `/dev/nvme0n1`, booted the
installed system, passed serial and SDDM password login and desktop health, and
completed two account-password change round trips. The login keyring unlocked
with the changed password. It used the same installer through its JSON-plan
interface with the minimal optional application selection.

The final encrypted test used the actual tty1 screen for development consent,
account entry, review and the erase confirmation, with all nine default
application groups enabled. It replaced an old ext4 installation. During stage
4, the Ethernet link was disconnected for **101.3 seconds** and restored.
Installation completed without restarting disk preparation. GPT and the
ESP/LUKS UUIDs were unchanged; the ESP was exactly 16 GiB, `sgdisk -v` passed,
and the second disk's marker was unchanged.

The live runtime rejected mounted filesystems, read-only disks, active swap,
an unmounted open LUKS mapping and a 63 GiB disk. Source tests additionally
cover LVM, RAID and multipath mappings. The plain test covered NVMe partition
naming; both installations retained the exact ISO source NAR.

For this outage test only, the live guest's Nix download attempts were set to
one and its connection timeout to three seconds. Product defaults were not
changed. The full-install harness did **not** observe the worker's waiting
message before the link returned. The separate real Nix transfer above
exercised that wait/resume branch. The successful full installation and its
unchanged partition identities establish that the outage did not cause
repartitioning or formatting to run again.

The encrypted system booted from the installed disk, passed disk unlock,
serial password login, the candidate desktop check and SDDM password login.
The account/disk/keyring password was changed and changed back through the
packaged worker and PAM, with a reboot and successful login after each change.
The old disk key was rejected and the login keyring unlocked with the new
password. Desktop checks verified a sole managed Quickshell process and the
current invocation's QML journal before and after the password changes.
Actual review, completion, connected-Wi-Fi and installed-desktop captures were
inspected. The final completion logo no longer overlaps its heading.

## Other verification

- Final ISO/source/package parity: **39 checks passed**, including exact source
  NAR, installer screen/service, shared installation contract and offline payload.
- Final lifecycle/source build: **573 tests** and **21 system-settings tests**
  passed. The unchanged network helper regression suite also passed 62 Node tests.
- Final installer package: **32 Rust tests** passed: 20 unit, eight rendered
  interaction and four presentation tests.
- Actual staged updater: software and maintenance candidates reached `ready`;
  machine locks, personal declarations/sentinel and running maintenance policy
  were preserved. Candidate desktop checks passed. The driver, including the
  real network-transfer recovery check, finished in **131.41 seconds**.
  Guest-only NAT/DNS was supplied after its network-profile assertions.

## Limits

These results qualify the exercised virtual installation and network flows.
Physical Wi-Fi adapters, firmware and radio conditions remain untested.
Enterprise/802.1X, hidden networks and captive portals were not exercised.
Live Wi-Fi credentials intentionally remain installation-only; reconnect from
the installed desktop after boot. Signed production installation, applied
channel updates, physical hardware and Secure Boot enrollment are outside this
audit. The installer continues to refuse unsupported Secure Boot installation.

No host disk was partitioned or formatted, the host network configuration was
unchanged, and the host was not rebooted. No release was published.


## PXE delivery and cleanup

The retained testing ISO is **7,120,576,512 bytes (6.63 GiB)**; its adjacent
`.iso.sha256` file is **114 bytes**. Both paths are listed above and in the JSON
evidence. The human-readable report and bounded JSON evidence are retained in
`docs/measurements/` for review.

iVentoy refresh returned `result: success`, settled to `running`, listed the
final `wifi-audit-v4.iso` and excluded the superseded task images. The pre-existing
`cybexos-1.0.0-beta.2-20261024-2c0c4bcab02f.iso` was preserved.
`iventoy.service` remained active; no restart was needed. The final ISO checksum
was verified again after removing the duplicate Nix ISO outputs.

All **33 task leases** were independently checked: closed, no remaining
resources, preserved volumes or cleanup errors. No task QEMU/process or mount
remained. VM disks, source snapshots, raw logs and screenshots were removed.
The unique staging directory
`/data/tmp/cybexos-installer-audit-20261024-upyyha15` was removed and its absence
verified; all 33 lease workspaces were absent. Five empty owned QMP control
directories were removed with `rmdir` after checking for process, working-directory
and Unix-listener references; their exact paths and checks are in the JSON.
Existing user image directories and unrelated services were left alone.
