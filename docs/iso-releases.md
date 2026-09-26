# ISO and desktop RPM releases

CybexOS ISO releases and source archive releases share a version tag but have
separate build gates and artifacts. A trusted Debian 13 PXE runner builds the
ISO and desktop RPM and exercises the installer in disposable guests. It
transfers only the build artifacts and qualification reports. A separate
GitHub-hosted signing job prepares the signed desktop assets; private signing
material never goes to the PXE host. Signed RPM repository metadata is deployed
to GitHub Pages after the GitHub Release has been published and confirmed
immutable.

The desktop update endpoint is
[`https://digitalpals.github.io/CybexOS/44/x86_64`](https://digitalpals.github.io/CybexOS/44/x86_64).
Pages serves `update-channel.json`, the public key, signed release and
`repodata`; the RPMs themselves are assets of the matching immutable GitHub
Release. The channel configuration is [stable.json](../image/channels/stable.json),
which pins signing fingerprint
`16C60642B7278AECE3A933C354220839FDF7099E`.

## Repository and runner setup

The GitHub repository already has immutable releases enabled and GitHub Pages
configured. The Pages site is empty until a release is published. The
`desktop-release` Actions environment and its `CYBEXOS_RPM_SIGNING_KEY` secret
are configured. The secret contains the RPM signing subkey and is used only by
the GitHub-hosted Fedora 44 signing job. The PXE runner receives no private
signing material. The primary private key remains in a protected local
keyring; move it to offline custody before public release. Never print or copy
signing material into the checkout or expose it in workflow arguments or
logs.

Before the first public release:

- The repository includes its MIT license. This covers repository code; it
  does not settle redistribution rights for third-party software and bundled
  assets. Complete that audit before public distribution; see
  [licensing and asset provenance](licensing.md).
- Enable a trusted Debian 13 x86_64 self-hosted GitHub Actions runner on the
  PXE host with labels `self-hosted`, `linux`, `x64`, and `cybexos-iso`. It
  needs `/dev/kvm`, at least 180 GiB staging space and 24 GiB available RAM,
  the `image/build --preflight` dependencies, a Chromium browser executable,
  access to `/data/pxe/iso`, and a running `iventoy.service`. The job installs
  Node 24 and `playwright-core` in its isolated workspace. It is restricted to
  this repository's `main` and version tag refs; never expose it to
  untrusted pull request code. The runner builds and qualifies only; the
  GitHub-hosted signing job uses the protected environment secret.
- Repository variable `CYBEXOS_BASELINE_ISO` is configured as
  `/data/pxe/iso/CybexOS-Live-44-20260926T055804Z-dbdd33d6.iso`. Keep this older
  supported ISO and its matching `.sha256` sidecar in place. The qualification
  job requires a regular, checksum-verified ISO under `/data/pxe/iso`.
- The runner must be enabled and all release gates must pass. The qualification
  has to pass on the exact release build; configuring Pages, the baseline
  variable, and signing environment alone does not make a public desktop
  channel available.

The release checks the source contract, image-source contract, and a
twice-converged generic Fedora VM before calling
[desktop-release.yml](../.github/workflows/desktop-release.yml) on the trusted
PXE runner. Its `qualify` job builds the ISO with the public stable channel,
publishes the completed testing ISO and checksum to iVentoy, and runs five
QEMU guests with isolated disposable disks. It uploads only the raw build
artifacts and bounded qualification reports as `cybexos-qualified-desktop` for
two days. The separate GitHub-hosted `sign` job downloads that exact artifact
and produces `cybexos-desktop-release`; it retains the prepared assets for two
days and qualification evidence for fourteen days. The signing job needs a
Docker-capable GitHub-hosted runner with at least 24 GiB free staging space.

| Scenario | Encryption | Keyboard and locale | Timezone |
| --- | --- | --- | --- |
| `encrypted-us` | LUKS | US / `en_US.UTF-8` | UTC |
| `plain-us` | Off | US / `en_US.UTF-8` | UTC |
| `encrypted-nl` | LUKS | Dutch / `nl_NL.UTF-8` | Europe/Amsterdam |
| `plain-nl` | Off | Dutch / `nl_NL.UTF-8` | Europe/Amsterdam |

Each of the four fresh scenarios boots the exact candidate ISO and completes
the graphical installer. A fifth guest uses the older baseline ISO, creates a
recovery point, applies the exact candidate desktop RPM, then boots and restores
that pre-upgrade point and verifies that the baseline RPM is active again. This
older-image upgrade and recovery qualification is separate from the four
fresh-install scenarios.

A release is rejected unless qualification reports identify the SHA-256 of the
exact ISO and candidate RPM and all five scenarios pass. Reports are retained
as bounded workflow artifacts; the desktop assets are retained briefly for the
publishing job. Do not treat source fixtures, a local RPM build, or an earlier
ISO boot as a substitute for these release gates.

## Published assets and ISO reconstruction

The publishing job creates the tagged source archive and its offline-verifiable
provenance bundle, then uploads those with the desktop release assets and
`SHA256SUMS` to a draft GitHub Release. It publishes the draft after uploading
all assets, then polls until GitHub marks the release immutable; failure to
confirm immutability fails the workflow after publication. Only after this job
passes does a stable tag deploy signed metadata to Pages. A prerelease tag
publishes downloadable assets but does not update the stable Pages repository.
The ISO is split into files below GitHub's per-asset size limit. `assets/` also
contains the part manifest, original ISO SHA-256 file, reconstruction script,
qualification reports, signed RPMs, and `desktop-SHA256SUMS`.

Download `desktop-SHA256SUMS` and every file it names into one directory, then
verify and reconstruct without replacing an existing output:

```bash
sha256sum -c desktop-SHA256SUMS
python3 reconstruct-iso.py CybexOS-Live-44-BUILD-ID.iso.parts.json
sha256sum -c CybexOS-Live-44-BUILD-ID.iso.sha256
```

The reconstruction tool checks each ordered part against the JSON manifest,
then checks the complete ISO size and SHA-256 before publishing the output.
It refuses to overwrite an existing ISO. Keep the manifest, parts, and helper
in the same directory. Check the signing fingerprint independently before
trusting the RPM or channel metadata.

After the immutable GitHub Release is available, the Pages job deploys the
signed metadata snapshot. Metadata points each package URL at that release's
RPM asset, so Pages never needs to host the large RPM. Publication is ordered:
the Pages deployment waits until the immutable Release and RPM assets exist.
Until both jobs complete successfully, the channel is not ready for enrollment.

## Enroll the installed RPM channel

The default ISO bundles a disabled channel. Check the installed system with
read-only diagnostics:

```bash
cybex doctor --json
cybex update-channel status --json
```

For enrollment, obtain `update-channel.json` and `CYBEXOS-desktop.asc` from the
same published release's verified assets, keeping them together in one
folder. Review the URL and compare the configuration's full fingerprint with
the independently trusted value above. Validate connectivity and signatures
without changing the system:

```bash
cybex update-channel enroll /path/to/release/update-channel.json \
  --fingerprint 16C60642B7278AECE3A933C354220839FDF7099E --check
```

When the check succeeds, explicitly enable the repository:

```bash
sudo cybex update-channel enroll /path/to/release/update-channel.json \
  --fingerprint 16C60642B7278AECE3A933C354220839FDF7099E
cybex update-channel status --json
```

Enrollment verifies the public key fingerprint and signed repository metadata,
then pins the public key and repository configuration locally. It does not
install an update. The ordinary system package update path can install the
signed desktop RPM once the channel is ready. `cybex update --check` is a
source-checkout command and is not supported for ISO installations. Key
rotation requires a separately reviewed migration; do not enroll a different
fingerprint as a routine update.

The current GitHub repository has not published its first public release and
the Pages endpoint is still empty. The repository has selected the MIT
License for its code, but the bundled software and asset redistribution audit
still applies. The enabled trusted runner and complete release workflow must
pass before signed desktop metadata is available to users.
