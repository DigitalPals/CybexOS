Describe the concrete behavior changed and why.

Validation:

- Source/module tests and candidate desktop checks:
- Real ISO/installer/updater scenarios exercised:
- Exact tested source revision and NAR identity:
- Personal configuration/state and public plugin API coverage:
- Hardware/security checks, limitations and release blockers:
- Task-created artifacts retained (path, size, reason) and cleanup:

A fixture suite or Nix build is not end-to-end qualification. Product policy
belongs in shared NixOS modules; never silently discard personal configuration
to make an update pass.
