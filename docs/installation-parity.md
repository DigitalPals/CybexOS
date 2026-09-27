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
| Additional local-network firewall ports | Disabled; LocalSend retains its shared ports |
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
seeded only when absent, as on the ISO. Managed Fish and Kitty fragments remain
updateable independently of those personal files.

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
