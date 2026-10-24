# Google DNS defaults and Tailscale investigation

Fresh live and installed NerdOS systems now initialize an editable wired
NetworkManager profile with Google DNS: `8.8.8.8`, `8.8.4.4`,
`2001:4860:4860::8888` and `2001:4860:4860::8844`. DHCP still supplies addresses
and routes; its DNS servers are ignored on that initial profile. The profile
supports multiple wired adapters. New Wi-Fi connections created through the
desktop or installer inherit the selected provider, with Google as the first
Wi-Fi default when no physical profile exists.

The shared module copies the wired profile into mutable state once, before
NetworkManager starts. It leaves existing profiles alone. Later selections,
including Automatic, are not restored to vendor values by the initializer.
Other network tools retain control of profiles they create.

NetworkManager and Tailscale now share systemd-resolved, with the recommended
stub resolver and Google fallback servers. Tailscale's authentication and DNS
preferences are unchanged. The installer records upstream resolvers, DNS routing
domains, Tailscale's backend state and verified HTTPS connectivity. It suppresses
Tailscale's full status output, which can contain an authentication URL. The
connection-error screen also offers **Show installation details**. Network
checks do not rewrite profiles or disconnect interfaces.

## What the Tailscale investigation established

The previous live configuration used NetworkManager's `dns=default` with
openresolv. It had no configured static nameservers; Automatic accepted the
network's DHCP DNS. Tailscale was enabled on the ISO, but no authentication key
or automatic login was configured. The original machine was powered off, so
its actual resolver address and installation log could not be recovered.

Tailscale can change DNS after sign-in. MagicDNS can use its local resolver at
`100.100.100.100`, and a tailnet's **Override DNS servers** setting can replace
local upstreams. That address is a normal Tailscale resolver, not evidence of
an incorrect DNS address by itself. A fresh client cannot assume that a
tailnet-only upstream is reachable before authentication. These mechanisms make
Tailscale relevant to investigate, but do not establish that it caused this
particular failure.

Upstream recommends systemd-resolved for Linux DNS integration. The pinned
Tailscale 1.98.10 source skips authenticated network reconfiguration without a
network map and clears engine DNS in `NeedsLogin`. Both isolated boot checks
observed `NeedsLogin`, no Tailscale DNS servers, working Google DNS, and
Tailscale selecting `systemd-resolved` / `*dns.resolvedManager`. No tailnet
account was used, so signed-in MagicDNS, exit nodes and administrator DNS
overrides were not runtime-tested.

Sources consulted:

- [Tailscale: Linux DNS](https://tailscale.com/kb/1188/linux-dns).
- [Tailscale: why resolv.conf is overwritten](https://tailscale.com/kb/1235/resolv-conf).
- [Tailscale: DNS settings and overrides](https://tailscale.com/kb/1054/dns).
- [Tailscale 1.98.10 Linux DNS manager](https://github.com/tailscale/tailscale/blob/v1.98.10/net/dns/manager_linux.go).
- [Tailscale 1.98.10 backend state handling](https://github.com/tailscale/tailscale/blob/v1.98.10/ipn/ipnlocal/local.go).
- NetworkManager 1.56's packaged `NetworkManager.conf(5)`: global DNS
  overrides connection DNS, so an unconditional global override would defeat
  later network-widget choices. The implementation instead uses editable
  connection settings.

## Exact source and validation

- Frozen source: `/nix/store/ni1rpimamdhb6620cs0kqyh4hzhbagln-source`.
- Source NAR: `sha256-wGhKUL/M4wMKjcTXZt/YSFxwhBR7vZkT7anEc0SqrGQ=`.
- Version `1.0.0-beta.2`, revision `uncommitted`. This development testing
  image includes the checkout's pre-existing work. It is not a published or
  authenticated release.
- All 526 Python discovery tests and the additional standalone helper suites
  passed. JavaScript: 1,360 passed, 17 skipped. The focused installer/network
  suite passed 45 tests. Native Qt/controller checks passed, including the new
  preflight details action, persistent failure logs, timezone behavior and the
  existing private review and close guard.
- The shared installation-contract build passed. All 36 completed-image/source
  parity checks passed, including source NAR, installer frontend/QML, worker,
  packages, release metadata and boot profiles.
- The actual staged updater passed the final source's complete, unchanged VM
  test script: 139.14 seconds for the script, 162.23 seconds including boot and
  cleanup. Driver:
  `/nix/store/fscqndhvyr38k8d5ll1cxa35l519s0wh-nixos-test-driver-nerdos-lifecycle`.
  Script SHA-256:
  `9980537df40c4b0af54a433d48cc299f8c8289c2742be351a2b623da4591e8d6`.
  The VM automatically obtained internet through the new Google profile; no
  injected DHCP connection or substituted updater assertions were needed.
  Software and maintenance candidates reached `ready`, and personal content,
  configuration hashes, locks and the running maintenance policy were
  preserved. Nothing was applied.
- In that VM, DHCP advertised `10.0.2.3`; active DNS used Google instead.
  Selecting Automatic through the packaged helper survived restarting
  NetworkManager and the initializer. Removing the initializer marker and
  rerunning it also preserved the existing profile.
- The completed ISO booted through its actual UEFI bootloader in a disposable
  KVM VM. Its declared bundled source has a different Nix store name but the
  same independently verified NAR. Google DNS and verified HTTPS worked with
  Tailscale signed out. A real JSON installer preflight reached `ready` and was
  cancelled. After deliberately selecting the unreachable resolver
  `192.0.2.53`, preflight stopped with an error before setup; its accessible
  private log showed that resolver, `NeedsLogin`, and curl's resolving timeout
  (exit 28). Restoring Google through the packaged helper restored HTTPS.
  The disposable disk's layout remained unchanged. This check took 47.09
  seconds; it did not attempt a fresh installation.
- The live VM's Quickshell guard compared the authenticated user's service
  MainPID with every shell process, including Qt-wrapped Quickshell, at the
  start and end. Exactly one managed shell remained and its invocation's
  journal passed the QML/runtime error check.
- Initial harness assertions were corrected to follow NixOS's `/etc/static`
  indirection and the ISO's declared source path. Those corrections did not
  change resolver behavior. The final script was checked byte-for-byte before
  and after running. The writable snapshot retained its NAR, and all 1,476
  checkout entries matched the frozen source before adding this evidence file.
  `git diff --check` passed.

These checks qualify the tested DNS defaults, live preflight diagnostics and
local staging behavior. They do not establish the original machine's exact
failure, a completed fresh installation, physical PXE/hardware support, Secure
Boot, an applied update, or signed-in Tailscale DNS behavior. No running
workstation was deployed, partitioned or rebooted.

## Retained PXE deliverable

On **thebeast (`10.10.0.7`)**, retained for the next installation test:

- `/data/pxe/iso/nerdos-1.0.0-beta.2-20261023-google-dns-c0684a50bfcc.iso`
  (10,241,591,296 bytes; 9.54 GiB).
- The same path plus `.sha256` (123 bytes).
- ISO SHA-256:
  `e7684cb092556929c564f5b256d98b2b6b26ed0ee4ae116a6557264a1b12f1c2`.

The complete image and checksum were copied and verified outside the served
tree, then linked into place atomically with readable permissions. The served
checksum passed before refreshing iVentoy. Refresh returned
`{"result":"success"}`, then status moved from `refreshing` to `running`.
The image tree contained the new filename and all three previously listed
images. `iventoy.service` was active; no restart or existing-image removal was
needed.

## Cleanup

Removed `/tmp/nerdos-installer-dns-Z1iXsW` on the Beast (41 MiB) and
`/scratch/tmp/john/nerdos-installer-dns-apc3enme` locally (9.3 MiB), including
source snapshots, attempted-test logs, VM disks, firmware variables and
screenshots. Parity extraction removed its temporary tree. Removed the separate
copy-staging directory `/home/john/.cache/nerdos-google-dns-iy5om451`; its hard
links had already been added to the served directory.

The cancelled first image build left no ISO output. Removed the final duplicate
ISO output through Nix after removing its task outlink:
`/nix/store/6lww3n927xd675h0a2d8q7lbhpj54g38-nerdos-1.0.0-beta.2-x86_64-linux.iso`.
Nix reported 9.5 GiB freed. Nix build dependencies remain cached.

Final checks confirmed all three staging directories absent with zero retained
bytes, both task ISO store outputs absent, and no task processes or mounts on
either host. Neither host had a `~/.local/share/nerdos/images` directory. The
served ISO and 123-byte checksum remained present, with iVentoy active and PXE
status `running`. The only retained task artifacts are the testing ISO and
checksum listed above, together with this repository evidence record.
