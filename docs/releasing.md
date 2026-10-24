# Release delivery and publisher trust

Cybex OS uses semantic tags (`v1.2.3`, `v1.2.3-beta.1`), immutable GitHub
Releases, and small signed GitHub Pages documents under `channels/stable.json`
and `channels/beta.json`. Normal clients use public HTTPS without GitHub
credentials. A release is always selected by exact commit and NAR content
identity, never by checking out a moving branch after discovery.

The installed `release/keys/trust.json` is deliberately empty. An owner must
supply real Ed25519 publisher public keys before production installation or
Cybex OS channel updates can work. Upstream-only updates do not use this
channel. Do not ship a generated development key as publisher trust.

Keep private signing keys outside the repository and Nix store. The protected
`cybexos-release` and `cybexos-channel` GitHub environments hold separate
`RELEASE_ED25519_PRIVATE_KEY` and `CHANNEL_ED25519_PRIVATE_KEY` secrets, with
`RELEASE_KEY_ID` and `CHANNEL_KEY_ID` environment variables. Require owner
review, protected tags, and restricted workflow changes. Enable immutable
releases in GitHub settings before publication. Enable GitHub Pages with
Actions delivery and prepare its `gh-pages` branch; promotion preserves the
existing site. These settings and trust provisioning are release prerequisites.

The release environment also needs `IMMUTABILITY_CHECK_TOKEN`: a repository-
scoped GitHub App or fine-grained credential with **Administration: read**.
The ordinary Actions publishing token cannot read this policy. The workflow
checks GitHub's immutable-release setting before draft creation and again before
publication, and fails closed on a disabled setting or an unavailable API.
This separate credential cannot change the setting; publication still uses the
Actions contents token. Keep repository policy changes protected during release
publication. Installed users need neither credential nor a GitHub account.

Development commits may be pushed directly to `main`; pull requests and GitHub
Actions checks are optional. Run **NixOS qualification** on demand from the
Actions page, or invoke it through the release workflow. It does not run
automatically on pushes or pull requests. The release workflow still requires
qualification before publication.

Full Nix/product/image jobs require a `cybexos-isolated` self-hosted runner;
standard hosted runners do not provide enough space for the complete desktop,
build dependencies, ISO copies and installation VMs. Provision a fresh,
single-job disposable x86_64 Linux VM with at least 256 GiB of disk, 32 GiB
RAM, four CPU cores and accessible nested KVM. The preflight requires 160 GiB
free for the Nix store plus 32 GiB for work (192 GiB when they share a
filesystem), at least 24 GiB available memory, and KVM for VM/image jobs.
Build concurrency is bounded to two builds and four cores per build.
Discard the runner, workspace and attached disks after each job. It must have
no workstation data, persistent credentials, production network access or
production PXE mount. Untrusted pull-request checks receive no signing secrets;
only the protected publisher step receives its scoped signing secrets.
Runner provisioning and isolation are owner-managed release prerequisites,
not an instruction to enroll the running workstation as a runner.

1. Commit the final source, set VERSION and release notes, and create a semantic
   tag. Never reuse a tag. Record `nix flake metadata --json` revision/NAR.
2. Run source checks, real ISO installation and updater tests, plus representative
   physical hardware/security qualification on that exact revision. A complete
   report must use `installation-update-and-physical-qualification`, include
   `revision`, `narHash`, and every check in `release/manage.py:REQUIRED`, with
   passed results and reviewable evidence. A fixture report cannot pass the gate.
3. Run the protected release workflow with that tag and the reviewed report URL.
   It repeats checks/builds, prepares the ISO, versioned source, notes, checksums,
   qualification report and signed manifest, authenticates the local signature
   and every asset, then uploads all assets to a draft.
   Publication must produce an immutable release. The report URL is evidence
   supplied for owner review; it is not an independent hardware attestation.
4. Verify public assets against the authenticated manifest. Only then run the
   separate promotion workflow with a strictly increasing channel sequence.
   Stable rejects prereleases. Promotion authenticates the previous signed
   channel/release, rejects version downgrades and nonadvancing sequences, and
   verifies the selected release and every public asset before changing Pages.
   The signed version, exact commit and NAR must match the requested tag's
   checked-out source; a valid manifest copied from another release is rejected
   before its asset URLs are fetched.
   Expired channel documents can be renewed for the same release. An expired
   signing key requires the documented trust/recovery procedure.

Ed25519 signatures authenticate the exact JSON bytes using OpenSSL; detached
signature envelopes identify a trusted key and its purpose. The signed manifest
contains version, exact source revision/NAR, supported architectures and NixOS
releases, configuration/plugin APIs, minimum updater API, declared vendor inputs,
notes, and each asset's name, URL, size and SHA-256. The channel authenticates
the manifest hash, expiry and sequence. Unknown/expired keys, malformed metadata,
unsupported APIs/platforms, mismatched identities, replays and normal downgrades
are rejected before selected code evaluation. The machine records successful
channel sequence high-water marks outside user caches. Explicit retained-generation
rollback is separate from channel selection.

Clients use bounded downloads, atomic cached responses, ETags, and actionable
unavailable/rate-limit errors. An endpoint failure means unknown availability;
it never means current. Interrupted downloads do not change the working lock.
Expired channel documents must be re-signed and promoted with a greater sequence,
including when the release itself remains unchanged.

For rotation, first publish a release signed by an existing trusted release key
that adds the new public keys, validity dates and purpose restrictions. Keep
old and new keys overlapping until supported machines have installed that trust
update. Promote using the old channel key during the overlap, then switch to
the new channel key. Do not expire the only key usable by supported updaters.
Revocation of a compromised sole key requires an independently authenticated
recovery/trust update; signatures by that compromised key cannot establish new
trust. Increasing updater/schema requirements requires an overlap release that
old updaters can authenticate and install.

Nixpkgs supplies Quickshell, Qt, Hyprland, applications and fonts through the
machine's stable Nixpkgs input and upstream binary cache. Cybex OS supplies the
desktop interface, assets, native notification-image module and extensions.
Narrow Intel camera/OMaWrite/font source pins and the temporary Hyprland/native
library compatibility overlay are source derivations, not another Nixpkgs
universe; requalify their ABI/license constraints when updating them.
T3 Code is an exact hashed upstream AppImage wrapped with Nixpkgs because the
selected stable package set does not provide the application. Replace that
source recipe with the maintained Nixpkgs package when available, after product
runtime qualification; its successful wrapper build is not desktop validation.
The selected stable Nixpkgs ChatGPT recipe is macOS-only. The Linux recipe pins
OpenAI's versioned Debian pool object and SHA-256, reviewed against the signed
OpenAI repository metadata; it executes no distribution maintainer scripts or
repository enrollment. Preserve the Chromium sandbox and exact-executable
AppArmor user-namespace allowance when updating it. Replace the recipe with a
maintained native Nixpkgs Linux package after runtime qualification.

Brave Origin reuses the selected Nixpkgs Chromium wrapper/libraries and pins the
official Origin Debian asset because stable Nixpkgs does not yet select that
edition. Review both exact proprietary package pins on every vendor release;
replace the Origin override when a maintained equivalent enters Nixpkgs.
They remain part of the explicit proprietary-application choice and require
installed runtime, security and redistribution qualification.

The maintained NetworkManager Libreswan plugin uses Nixpkgs sources and a
scoped helper-path correction: the selected recipe points to `libexec/`, while
Libreswan 5 installs its daemon/controller helpers in `libexec/ipsec/`.
Build-time assertions check each replacement target. Cybex OS uses the native
NixOS `ipsec.service` to manage the backend; the plugin's legacy standalone
startup expects a removed `_stackmanager` helper. A working managed service is
therefore required and must pass installed health qualification.
Remove the override after the upstream recipe is
corrected and the installed VPN path qualifies; it does not suppress or patch
the archived vpnc plugin's vulnerabilities.
The reviewed desktop runtime series live in `desktop/runtime-compatibility.json`;
a candidate outside that matrix fails staging until qualified.

No durable Cybex OS binary cache is configured. Before advertising fast public
updates, provision a public Nix cache (for example an object-store-backed Nix
cache or Cachix), publish its independent Nix cache signing public key and
substituter URL, and prebuild each release/architecture. Add cache trust through
the shared module after reviewing that key. GitHub Actions artifacts and GitHub
Release download archives are not a public Nix binary cache. Source builds remain
possible; publisher metadata signatures and Nix cache signatures have different
purposes. Redistribution/license review remains required for the actual payload.

Physical/security qualification must include `mandatory-access-control` and
`firewall` evidence. Record enforced profile/process coverage, negative access
probes and packet-level policy behavior. AppArmor being enabled alone cannot
satisfy the mandatory access control check.
