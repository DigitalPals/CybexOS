# Rename to NerdOS

NerdOS is the Opinionated System at **nerdos.org**, formerly CybexOS.
This work targets fresh NixOS 26.05 installations. The Fedora/RPM/Ansible
bridge-release and installed-system migration instructions in the supplied
older rename kit do not apply to this repository's lifecycle contract.

## Implementation plan

Baseline: commit `0cf9be2`, clean `main`; implementation branch `rename/nerdos`.
The regenerated inventory has 2,260 old-name occurrences in text, compared with
the kit's 6,250-reference Fedora-era snapshot at `4f31668`. The current tree
uses NixOS modules, systemd-boot/Lanzaboote and Ed25519 release metadata.

1. Rename the NixOS module/input namespace, lifecycle Python package, CLI,
   installer, system/user units, desktop helpers, state paths and fixtures in
   reviewed groups. Preserve machine-owned inputs and personal ownership rules.
2. Rename Quickshell/native module identifiers, themes, widgets, translations,
   browser demo, documentation and the bundled skill. Preserve external source
   names and historical attribution; no command aliases or installation shims.
3. Import the supplied brand masters unchanged. Integrate the glasses, icons,
   fastfetch and favicons; package/select Plymouth through the shared NixOS
   module, including initrd assets and LUKS unlock. Keep theme colours unchanged
   outside brand surfaces.
4. Update release identity and infrastructure instructions without publishing,
   changing owner settings or touching signing material. Check source/ISO
   contract parity, staged lifecycle, authenticated delivery, web and leftovers.

## Status

Implementation and validation are in progress. No release, installed-system
migration, workstation activation, host reboot or infrastructure change is
authorized by this rename.

Baseline browser checks (`lint`, `typecheck`, `test`, `build`, `test:render`)
all passed. Host `tests/run` reached 420 Python tests with one failure, one
error and 15 skips; both failures were fingerprint-enrolment D-Bus tests.
The remaining source groups and isolated Nix baseline are being recorded.

Final validation, artwork coverage, exact hosting steps, commit list and
retained artifacts will be recorded here before handoff.
