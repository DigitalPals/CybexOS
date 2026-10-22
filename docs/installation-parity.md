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
| Next boot | Graphical login through SDDM; convergence leaves the current session running |
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
Docker membership uses the same ownership-aware grant/revoke policy on checkout,
ISO configuration and RPM reconciliation. An explicit saved choice for the
selected account can revoke Docker access even on an older ISO without an
ownership marker. Automatic convergence without that choice removes only
CybexOS-owned grants; independently administered access and unrelated groups
are preserved. Changes take effect in new login sessions. When repair first
records an older installation's choices, it retains existing Docker access
until the administrator explicitly changes it with `cybex configure`.
`--reconfigure` offers the saved boolean choices as its defaults. An explicit
identity change in the checkout questionnaire still applies that choice.
Neither parity nor a release update authorizes repartitioning an existing
Fedora installation or resetting user settings to match a clean account.
Shell preferences, including wallpaper selection, are seeded only if the
entire settings file is absent. An explicit empty wallpaper, sparse overrides,
unknown fields and future or corrupt documents remain unchanged on both paths;
concurrent creation of a settings file takes precedence over seeding.
Fastfetch, Voxtype, Oh My Posh, MIME associations, and npm configuration are
seeded only when absent, as on the ISO. Managed Fish, Kitty, Git and SSH fragments remain updateable while their bytes
match the shared ownership ledger. Conflicting edits and deletions are preserved
on both paths. Git/Kitty includes precede user values; SSH fallbacks follow them.
The default web apps (Slack, WhatsApp, YouTube, Google Photos and X) are seeded
once per account by the same helper, `cybexos-webapp seed`: the checkout's
dotfiles role runs it, and the ISO's `cybexos-user-init` runs it at
installation and login. The helper records each default it seeds, so a web app
the user removed is never added back on either path.

The checkout path installs onto existing Fedora and retains source-release
updates and uninstall; the ISO uses Anaconda for disk/account creation and RPM
delivery for desktop updates and repair. These mechanisms are distinct from the
installed policy.

`image/system_packages.py` reads the system selections and exclusions from
`image/live.ks` and the runtime requirements from the desktop RPM spec. After
the shared repositories are configured, checkout installs that contract,
including its package groups and version constraints. The local delivery RPMs
are supplied by checkout's application and desktop roles. Both paths disable
weak dependencies and use the complete shared locale and firmware baseline;
only device-specific configuration is gated on detecting the device. The
application builder leaves system composition to the ISO compose step.
Checkout resolves the ISO's full codec providers and `ocl-icd` in its first
base transaction, before desktop dependencies can select alternative providers.

Installer-only paths keep that policy. An unattended seed's `config` choices
(and the choices a factory reset keeps for the next owner) pass through
`installation_policy.choices`/`apply_choices`, the function the checkout
installer's saved-choice merge uses; `test_installation_parity.py` checks that
the same explicit choices produce the same configuration on both paths. The
new-owner setup provisions its account with the same fresh-account
`cybexos-configure-installed --offline` run as Anaconda's in-target hook. The
first-start, new-owner and factory-reset units ship only in the ISO's RPM
(with the graphical new-owner window and the `cage` package it needs): a
checkout installation runs on an existing Fedora system with its own account,
never has OEM state or a factory recovery point, and `cybex factory-reset`
explains that. Factory-point retention lives in the shared
`cybexos-system-snapshot`, so both paths prune identically. Comparing a development checkout with an older ISO is not a
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
feature cannot be added to only one installer's schema. Hardware roles run
unchanged on both paths: `image/test_nvidia.py` checks that the checkout and
the ISO's boot-time hardware setup apply the same NVIDIA role, payload and
session environment.

Recovery boot hooks preserve existing upstream directory permissions and
ownership on both paths. Fedora's
[`grub2-common-1:2.12-66.fc44` RPM](https://kojipkgs.fedoraproject.org/packages/grub2/2.12/66.fc44/noarch/grub2-common-2.12-66.fc44.noarch.rpm)
(SHA-256 `8482c540ca4badf57eaee30576af74f238bc23eabfd456498e00aa1a29d111b0`)
owns `/etc/grub.d` as `0700 root:root`; checkout must not force it to `0755`.
Checkout creates missing hook directories and manages its own root-owned files.
The image RPM owns the GRUB hook and vendor kernel-install hook, without
claiming their upstream parent directories. `image/test_update_recovery.py`,
also run by the source parity gate, executes the real Ansible tasks twice and
compares the RPM assembly with existing restricted and missing directories,
including preservation of administrator ownership.

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

Before invoking the public installer, qualification updates only its newly
created Cloud guest to the current Fedora OS baseline, removes the explicitly
listed preexisting Cloud packages, selects the generic Fedora release identity,
reboots onto the current kernel, and uses
DNF's supported old-installonly cleanup. The report records that preparation.
The public installer does not prune users' old kernels or package inventories.
The test asserts the installer's graphical boot target and SDDM enablement
instead of setting them after installation.

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
support, default boot target, filesystem and personal-file identities. Target
dependencies and per-user unit links can provide equivalent session activation;
masked/missing units and inactive services remain differences. The UTC timezone
alias is canonicalized for comparison without changing the saved choice.
It retains the complete RPM
inventories. Every additional package difference needs a reasoned entry in
`image/parity-exceptions.json`; required package/version differences always
fail. Exceptions cover the ISO delivery RPMs, Cloud provisioning tools and three
exact Brave prerelease key records. The signed `brave-keyring` package imports
them in its background postinstall script on running Fedora; the initial ISO
chroot lacks `timeout` at that point. Both paths have the same keyring payload
and pinned stable repository. The exception includes each full fingerprint and
RPM release; unknown keys still fail, and family-wide signing-key exceptions
are rejected. Review new actual baseline differences before extending that file.

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

The saved-choice ISO step uses `cybexos-configure-installed --offline` with
the prepared application payload, so outbound networking remains blocked
through reconfiguration. Checkout qualification runs the public installer
with its normal repository access. It prepares the shared codec repositories
and selects the ISO's final providers before base and desktop transactions,
avoiding dependencies left behind by replacing interim Fedora codecs.

`image/test_installed_outcomes.py` tests content identities, archive validation,
comparison guards and guest workflow construction without booting a VM. These
source tests do not qualify an installation or imply the expanded matrix ran.
New release evidence must come from executing the gate.
