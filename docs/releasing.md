# Publishing CybexOS releases

CybexOS has two release surfaces. Source-checkout releases publish a
versioned source archive; ISO releases publish a signed desktop RPM, bootable
ISO, and RPM update metadata. Both use a semantic-version Git tag and share
the repository source contract and generic Fedora VM gate. The release also
runs the image-source contract, then requires trusted PXE-host qualification
before publication. See [ISO and desktop RPM releases](iso-releases.md) for
runner setup, signing, the installer matrix, reconstruction, and channel
enrollment.

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
Users whose system apply failed keep their previous active release (`current`)
and their prior saved configuration, but files that Ansible had already
deployed from the failed candidate stay in place; the run records
`mixedState: true`. The corrected release converges them, and
`~/.local/share/cybexos/current/install` restores the previous release's files
in the meantime.

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
