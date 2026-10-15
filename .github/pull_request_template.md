## Summary

<!-- What changes and why. Link the issue it resolves, for example "Fixes #123". -->

## Installation paths

<!-- The ISO defines the product. A change to the installed product must reach
both paths in this pull request; see CONTRIBUTING.md. -->

- [ ] Not an installed-product change (documentation, CI, tests, or tooling only)
- [ ] ISO path covered (image packaging, `cybexos-desktop` RPM, provisioning, rootfs, repair, or reconcile as applicable)
- [ ] Source-checkout path covered (Ansible roles applied by `./install`)
- [ ] Parity regression coverage added or extended (for example `image/test_installation_parity.py`, `image/test_desktop_payload.py`, `image/test_installed_policy.py`, `image/test_user_parity.py`)
- [ ] Saved user choices and user-owned data are preserved

## Documentation

- [ ] User-facing documentation updated (README, `docs/`, `image/README.md`, `agent-skills/cybexos/references/`), or none is affected

## Checks

<!-- Paste the summary lines. Fixture suites are not end-to-end installation
tests; say so if a real installation was not performed. -->

- `./tests/run`:
- `python3 -B image/check-source`:
- Manual verification (hardware, live shell, VM), or why it was not needed:

## Dependencies and licensing

- [ ] New downloads are pinned by version or commit and checksum ([dependency policy](https://github.com/DigitalPals/CybexOS/blob/main/docs/dependency-policy.md)), or none were added
- [ ] New third-party code, artwork, fonts, or images have recorded provenance and a redistributable license ([licensing](https://github.com/DigitalPals/CybexOS/blob/main/docs/licensing.md)), or none were added

## Privacy

- [ ] No secrets, tokens, personal data, or unredacted logs in the diff, screenshots, or this description
