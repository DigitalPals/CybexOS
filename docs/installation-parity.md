# Installation parity

The ISO defines CybexOS's installed product. A checkout installation and an ISO
installation of the same release, on equivalent hardware with the same user
choices, must receive the same desktop, applications, account defaults,
authentication policy, services, firewall, and hardware configuration.

Fresh installations use these ISO defaults:

| Choice | Default on both paths |
| --- | --- |
| Applications | Every standard application group enabled |
| Personal defaults | Enabled, including Fish, Kitty, Git/SSH and browser preferences |
| Sudo and local Polkit | Password required |
| Docker administrator access | Sudo required |
| Desktop automatic login | Enabled only after complete root encryption is verified |
| Additional local-network firewall ports | Disabled; LocalSend and mDNS (printer and scanner discovery) remain open |
| Files SMB workgroup | `WORKGROUP`; explicit per-user workgroups take precedence |
| Machine identity | Preserve the identity already configured by Fedora/Anaconda |

`inventory/group_vars/all.yml` is the common default input.
`image/installation_policy.py` defines the account policy used by both
`scripts/installer-defaults` and the packaged `cybexos-config` helper. The
checkout questionnaire starts from that policy instead of maintaining its own
booleans. It uses the ISO's boot-time encryption verifier, including every
Btrfs member. Unverifiable or mixed encrypted/plaintext storage disables
automatic login. Real installs run this read-only probe with administrator
access; `./install --check` never elevates or installs dependencies and cannot
enable autologin if its access is insufficient to verify encryption.

Saved choices take precedence. Re-running or updating an installation must not
silently turn on personal defaults or passwordless access for an older account.
`--reconfigure` offers the saved boolean choices as its defaults. An explicit
identity change in the checkout questionnaire still applies that choice.
Neither parity nor a release update authorizes repartitioning an existing
Fedora installation or resetting user settings to match a clean account.
Fastfetch, Voxtype, Oh My Posh, MIME associations, and npm configuration are
seeded only when absent, as on the ISO. Managed Fish, Kitty, Git and SSH fragments remain updateable while their bytes
match the shared ownership ledger. Conflicting edits and deletions are preserved
on both paths. Git/Kitty includes precede user values; SSH fallbacks follow them.

The checkout path installs onto existing Fedora and retains source-release
updates and uninstall; the ISO uses Anaconda for disk/account creation and RPM
delivery for desktop updates and repair. These mechanisms are distinct from the
installed policy. Comparing a development checkout with an older ISO is not a
parity test: both artifacts must come from the same revision, with completed
hardware setup and equivalent application choices.

## Required checks for changes and releases

Run `./tests/run` and `python3 -B image/check-source`. Both required CI jobs run
`image/test_installation_parity.py`. It executes the real checkout questionnaire
and non-interactive dry run, then compares the complete generated configuration
with ISO provisioning and target finalization for encrypted and plaintext
installations. It also checks saved opt-outs, existing personal files, mixed or
unverifiable Btrfs, and the policy module shipped in the repair payload.

The existing image package, desktop payload, installed policy and user parity
tests cover package selections and shared task/template sources. Extend those
checks whenever a package, setting, service or hardware path changes; a new
feature cannot be added to only one installer's schema.

Release changes must pass the source and image gates from the same Git revision
and the existing generic Fedora and ISO installation/upgrade qualification
gates. Build and qualify a new ISO/RPM when its payload changes. Retain the
revision and artifact digests in the qualification evidence. Fixture checks
compare the installation contract; they are not evidence that fresh physical
or VM installations have been performed. Do not use an older ISO qualification
as evidence for a newer checkout.

## Real installed-outcome gate

`image/release-gate` requires two full checkout installations, `plain-us` and
`plain-nl`, in addition to the existing four graphical ISO installations and
prior-release RPM upgrade/recovery check. They use a checksum-pinned Fedora 44
Cloud image, the same QEMU hardware/UEFI configuration as the ISO guests, all
normal feature defaults, the public `./install --non-interactive` entry point,
and real SDDM password login after reboot. `tests/fedora-vm-convergence` remains
a separate convergence/uninstall test; its feature opt-outs cannot satisfy
this gate.

The builder includes the complete reviewed source set in `source.tar.gz`
alongside its ISO/RPM artifacts. A canonical digest covers file names, content
and executable bits, including intentional non-ignored working-tree changes.
It is embedded in the ISO's existing `build.json`. The builder verifies that
the archived content matches, so an edit during source capture aborts the
build. Checkout qualification extracts this exact archive, validates its
checksum and content, and requires the ISO qualification to identify that
exact source and ISO digest. Extraction rejects links, traversal and duplicate
paths. The runner's newer checkout cannot substitute for the tested source.

Each guest produces `outcomes-fresh.json`, then saves explicit shell/input
preferences, a valid personal Hyprland override and unknown future settings
fields. It reapplies its own installation path, reboots, verifies those values
survived and produces `outcomes-saved.json`. Captures require a running desktop
and exactly one Quickshell process owned by `quickshell.service`. The managed
Settings lifecycle test exercises Network, Sound, Online Accounts, Keyboard,
Touchpad and Region, including watcher cleanup and the current QML journal.

`image/installed_outcomes.py` compares effective shell/input settings, saved
installer choices, login policy, actual sudo authorization, Polkit policy,
account groups/shell, required RPM versions, Flatpaks, application commands and
associations, service enablement/activation, firewall policy, SELinux, recovery
support, filesystem and personal-file identities. It retains the complete RPM
inventories. Every additional package difference needs a reasoned entry in
`image/parity-exceptions.json`; required package/version differences always
fail. Initial exceptions cover only the ISO delivery RPM and Cloud provisioning
tools. Review new actual baseline differences before extending that file.

`parity-fresh.json` and `parity-saved.json` name mismatches. The release gate
embeds passed same-source checkout evidence in both plain ISO reports.
`image/prepare-github-release` also rejects missing, stale or fixture-only
parity evidence when invoked independently.

To rerun checkout comparison against a completed candidate (its corresponding
ISO qualification must have used `--capture-outcomes`):

```sh
image/qualify-checkout --execute-vm --scenario plain-us \
  --artifacts /path/to/build/artifacts \
  --iso-results /path/to/qualification/plain-us \
  --output /path/to/new-task-specific-checkout-output
```

The runner removes task-owned VM disks, SSH keys, cloud seeds, transient logs
and screenshots on success/failure, retaining compact reports.
`--keep-artifacts` retains unresolved diagnostics, but never the cloud seed or
SSH private key. Testing OS ISOs still use `/data/pxe/iso` and the existing
checksum/iVentoy workflow. Existing Fedora hosts are never repartitioned.

`image/test_installed_outcomes.py` tests content identities, archive validation,
comparison guards and guest workflow construction without booting a VM. These
source tests do not qualify an installation or imply the expanded matrix ran.
New release evidence must come from executing the gate.
