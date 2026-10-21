# Publishing CybexOS releases

CybexOS has two release surfaces. Source-checkout releases publish a
versioned source archive; ISO releases publish signed desktop and offline-apps RPMs, a bootable
ISO, and RPM update metadata. Both use a semantic-version Git tag and share
the repository source contract and generic Fedora VM gate. The release also
runs the image-source contract, then requires trusted PXE-host qualification
before publication. See [ISO and desktop RPM releases](iso-releases.md) for
runner setup, signing, the installer matrix, reconstruction, and channel
enrollment.

The large offline application seed has its own version in
`image/offline-payload.json`. Run `python3 image/offline_payload.py --version X.Y.Z`
with a newer version after changing its reviewed application inputs. Packaging
refuses a stale input digest. Shell-only changes keep that version and RPM
release unchanged; desktop RPMs retain their source/build identity. The desktop
also requires the exact application input digest, preventing an unrelated
newer offline package from satisfying its installation contract.

Treat a published offline NEVRA as immutable. Reuse its artifact for unchanged
inputs; if a moving upstream tool resolves differently, review it and advance
the offline version before publishing different payload bytes. Sign and ship
both RPMs together. The upgrade qualification installs both in one offline DNF
transaction and binds their checksums in the release report and SPDX SBOM.
The signing workflow authenticates the previous channel manifest and rejects
changed file contents or ownership under an existing offline NEVRA. Manual
repository signing must likewise pass `--previous-repository` with the previous
signed directory or its HTTPS URL. A missing public manifest (HTTP 404) allows
the first release; invalid signatures and other download failures stop signing.

An older installed baseline can need additional Fedora RPMs for a candidate's
SDK dependencies. Supply those only as an optional qualification fixture with
`image/qualify ... --candidate-dependencies DIR`. Do not publish them as
first-party release artifacts.
Keep a flat directory of signed, verified candidate-build downloads and a
separate provenance JSON mapping each RPM filename to
`{"id": "fedora", "url": "https://.../original-repository/"}`. On a host with
`rpm`, create and verify its manifest with:

```bash
python3 image/offline_upgrade_inputs.py create DIR --provenance provenance.json \
  --baseline-iso BASELINE.iso --candidate-rpm DESKTOP.rpm --candidate-offline-rpm OFFLINE.rpm
python3 image/offline_upgrade_inputs.py verify DIR \
  --baseline-iso BASELINE.iso --candidate-rpm DESKTOP.rpm --candidate-offline-rpm OFFLINE.rpm
```

Manual generators may write `DIR/manifest.json`: the exact top-level keys are
`schema` (integer `1`), `baseline_iso_sha256`, `candidate_rpm_sha256`,
`candidate_offline_rpm_sha256`, and `rpms`. Each RPM record has exactly
`filename`, `name`, `nevra`, `architecture`, `sha256`, `size` (bytes),
`signature` (`{"tag": "RSAHEADER", "value": "<rpm pgpsig output>"}`), and
`repository` (`id` and HTTPS `url`). NEVRA includes the numeric epoch, including
zero: `name-0:version-release.x86_64`. Signature values come from
`LC_ALL=C TZ=UTC rpm -qp --qf '%{RSAHEADER:pgpsig}'`; `DSAHEADER`, `SIGPGP`, and `SIGGPG` are also
supported. The JSON file's SHA-256 is the bundle identity, binding every RPM's
identity, bytes and provenance to all three input artifacts.

Admission rejects symlinks, traversal, duplicate identities, unknown fields,
extra/missing files, non-x86_64/noarch RPMs and mismatches. Limits are 256 RPMs,
512 MiB per RPM, 2 GiB total and a 1 MiB manifest. Root copies both candidates
and all dependencies into fresh private staging files using bounded,
no-symlink reads, then verifies the copied hashes, NEVRAs and signature headers.
Only those root-owned copies are checked and installed; changing the original
account-owned transfers cannot change the transaction. Dependencies pass
`rpm --checksig --verbose` using installed trust keys; no keys are imported.
Root staging is removed on success or failure. Qualification creates a bootable recovery
point before installing both candidates and all dependencies in **one** DNF
transaction with every repository disabled. `--recovery-check` additionally
boots and restores that point. `qualification.json` records the bundle digest,
identities and verified signatures. This input targets exact prebuilt upgrade
artifacts; release-gate's fresh-build workflow does not accept a prebound bundle.
Omitting the option retains the existing upgrade path.

The source archive is published by `.github/workflows/release.yml` after all
required jobs pass. Its prerequisite job checks the tag against `VERSION`,
requires a non-empty `CYBEXOS_BASELINE_ISO` repository variable and a root
license file, and validates semantic versioning. The ISO job additionally
validates that the baseline file and checksum sidecar exist on the PXE host.

## Source archive setup

1. Immutable GitHub Releases are enabled for the repository. Keep Actions
   permitted to create attestations and write release contents; the workflow
   grants only those job-level permissions.
2. The `desktop-release` environment and its `CYBEXOS_RPM_SIGNING_KEY` secret
   provide signing access only to the GitHub-hosted signing job. The PXE
   qualification runner never receives that secret. The `github-pages`
   environment deploys stable repository metadata after release publication.
3. Keep `CYBEXOS_BASELINE_ISO` set to the verified older ISO and configure the
   on-demand trusted self-hosted PXE runner as described in
   [the ISO release guide](iso-releases.md).
4. Branch protection requires pull requests, up-to-date branches, and the
   GitHub Actions checks `Fedora 44 source contract` and `Image tooling,
   installer fixtures and account isolation`. Admins are subject to the rule;
   force pushes and branch deletion are disabled. The generic Fedora VM is a
   release-tag gate, not a required branch check.

The updater refuses a release when GitHub reports `immutable: false`, even if
the archive checksum is otherwise correct.

GitHub Pages is configured at the desktop update URL but is currently empty;
the first stable ISO release workflow will deploy signed metadata there.
Prerelease tags publish downloadable assets but do not update the stable Pages
repository.

## Source archive release checklist

1. Review `release-manifest.json`, `VERSION`, the Fedora release,
   configuration schema, minimum updater version, and all dependency pins.
2. Run `./tests/run` and `./tests/fedora-vm-convergence` locally when practical.
   Run `python3 -B image/check-source` as well. Both source suites enforce the
   [ISO-leading installation contract](installation-parity.md); changes to
   applications, defaults or policy must cover both installation paths. Build
   and qualify ISO/RPM artifacts from the same release revision rather than
   reusing an older image as parity evidence.
   The source gate includes an N to N+1 ownership test that advances vendor
   runtime while requiring every user customization sentinel to remain
   byte-identical.
   The user-widget fixture also loads a fixed API 1 package outside the
   runtime through simulated replacement and rollback. Retain supported API
   adapters when changing the shell; see [the widget contract](architecture/user-widgets.md).
3. Commit the intended source and create a signed semantic-version tag, such
   as `git tag -s v1.0.0 -m 'CybexOS 1.0.0'`.
4. Push the commit and tag. A version containing a hyphen, such as
   `v1.1.0-beta.1`, is published as a prerelease for the beta channel.
5. Wait for the workflow to build, attest, verify the provenance bundle
   offline, upload, publish, and confirm the immutable release before
   announcing it.
6. On a clean supported machine, run `cybex update --check --json`,
   apply the release, and run `cybex verify --system`.

Do not edit an existing release. Immutability makes correction explicit: fix
forward, increment the version, and publish a new tag. If rollout must stop,
remove the bad release from channel discovery and publish a corrected release.
On the managed Btrfs layout, failed application or health validation selects
the previous root and restores the vendor desktop checkpoint while preserving
personal settings; users must restart to enter the restored root. Interrupted
application is recovered before login. On other filesystems the updater reports
`transactionProtection: unavailable`: failed activation restores the previous
`current` and saved configuration, but partially deployed files can remain
(`mixedState: true`). Converge the active release with
`~/.local/share/cybexos/current/install` or apply a corrected release.
See [update recovery and its limits](operations.md#update-recovery-points).

## What the source workflow publishes

The release contains a versioned source archive, its provenance bundle
`cybexos-VERSION.tar.zst.sigstore.jsonl`, and `SHA256SUMS`. The checksum
entries use the asset basenames, so they can be verified directly after the
files are downloaded into one directory. The archive
is reconstructed from the tagged Git tree, its `VERSION` and manifest version
are set to the tag, its installer is checked, and Ansible syntax is validated.

The bundle is the Sigstore bundle of the `actions/attest` provenance
attestation. Before publishing, the workflow verifies it offline without a
token, exactly as installed systems do:

```bash
gh attestation verify cybexos-VERSION.tar.zst \
  --bundle cybexos-VERSION.tar.zst.sigstore.jsonl \
  --repo DigitalPals/CybexOS \
  --signer-workflow DigitalPals/CybexOS/.github/workflows/release.yml \
  --source-ref refs/tags/vVERSION --deny-self-hosted-runners
```

The same attestation has a second subject: the ISO's SPDX SBOM,
`CybexOS-Live-44-BUILD-ID.spdx.json`, which the workflow also verifies offline
with this bundle. A separate SPDX attestation binds the SBOM to the ISO digest
and is published as `CybexOS-Live-44-BUILD-ID.iso.sbom.sigstore.jsonl`;
`SHA256SUMS` lists that bundle. See [the SBOM section of the ISO release
guide](iso-releases.md#software-bill-of-materials) for its contents and
verification.

That offline attestation check, the immutable-release flag, and the API
SHA-256 digest form the updater trust boundary. Updating needs no GitHub
login, and a release without its bundle is refused. Files copied from an
arbitrary branch or mutable URL are not accepted as updates.

Until a source archive release is published, source-checkout
`cybex update --check` reports that no release exists on its channel. On ISO
installations, use `cybex update-channel status --json`; that command's channel
status is separate from source archive discovery. See [ISO and desktop RPM
releases](iso-releases.md) for channel enrollment after the first stable
desktop release has been published.
