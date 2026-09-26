#!/usr/bin/env python3
"""Fixture the camera rollback gate without touching RPM, DKMS, or systemd."""

from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "roles/xps-2026/templates/xps-ipu7-build.j2"


def function(source: str, name: str) -> str:
    start = source.index(f"{name}() {{")
    lines = source[start:].splitlines()
    for index in range(1, len(lines)):
        if lines[index] == "}":
            return "\n".join(lines[: index + 1])
    raise AssertionError(f"unterminated shell function: {name}")


def fixture_script() -> str:
    source = BUILDER.read_text(encoding="utf-8")
    functions = "\n\n".join(
        function(source, name)
        for name in (
            "dkms_version_for_package_manifest",
            "dkms_version_for_manifest",
            "valid_identity",
            "valid_role_target_nevra",
            "installed_dkms_version",
            "snapshot_installed_rpm",
            "rollback_rpm",
            "rollback_nevra",
            "prepare_rollback",
            "verify_transaction_marker",
            "transaction_marker_field",
            "transaction_info",
            "guard_unresolved_build",
            "begin_transaction",
            "loaded_transaction_needs_reboot",
            "reboot_marker_state",
            "write_reboot_marker",
            "required_dkms_modules",
            "camera_modules_loaded",
        )
    )
    functions = functions.replace("/sys/module", "$FIXTURE_ROOT/sys-module")
    return f"""#!/usr/bin/bash
set -euo pipefail
rpm_dir=$FIXTURE_ROOT/rpms
output_rpm=$rpm_dir/xps-ipu7-camera-stack.rpm
output_manifest=$rpm_dir/xps-ipu7-camera-stack.inputs
output_checksum=$rpm_dir/xps-ipu7-camera-stack.rpm.sha256
rollback_root=$rpm_dir/rollback
state_dir=$FIXTURE_ROOT/state
transaction_marker=$state_dir/transaction.in-progress
dkms_source_root=$FIXTURE_ROOT/usr-src
bundle_version=1.0.5.xps6
old_manifest=$(printf 'a%.0s' {{1..64}})
new_manifest=$(printf 'b%.0s' {{1..64}})
FIXTURE_INSTALLED_NEVRA=xps-ipu7-camera-stack-1.0-1.xpsold.x86_64
FIXTURE_INSTALLED_VERSION=1.0
FIXTURE_CACHED_NEVRA=$FIXTURE_INSTALLED_NEVRA
FIXTURE_INSTALLED_IDENTITY=manifest=$old_manifest
target_identity=manifest=$new_manifest
target_nevra=xps-ipu7-camera-stack-${{bundle_version}}-1.xps${{new_manifest:0:16}}.fc44.x86_64

installed_identity() {{ printf '%s\n' "$FIXTURE_INSTALLED_IDENTITY"; }}
installed_manifest() {{ printf '%s\n' "$old_manifest"; }}
cached_target_identity() {{ printf '%s\n' "$target_identity"; }}
cached_target_nevra() {{ printf '%s\n' "$target_nevra"; }}
rpm() {{
  if [[ $1 == -K ]]; then
    return 0
  fi
  if [[ $1 == -q ]]; then
    case $3 in
      '%{{VERSION}}') printf '%s' "$FIXTURE_INSTALLED_VERSION" ;;
      '%{{NEVRA}}') printf '%s' "$FIXTURE_INSTALLED_NEVRA" ;;
      *) return 2 ;;
    esac
    return 0
  fi
  if [[ $1 == -qp ]]; then
    if [[ ${{*: -1}} == "$output_rpm" ]]; then
      printf '%s' "$FIXTURE_CACHED_NEVRA"
    else
      printf '%s' "$FIXTURE_INSTALLED_NEVRA"
    fi
    return 0
  fi
  return 2
}}

{functions}

install -d -m 0755 "$rpm_dir"
printf old-rpm >"$output_rpm"
sha256sum "$output_rpm" | awk '{{print $1}}' >"$output_checksum"
printf '%s\n' "$old_manifest" >"$output_manifest"
snapshot_installed_rpm

# Model interruption after the cache atomically switched to the new RPM while
# the old, healthy RPM remains installed. prepare_rollback must use the durable
# old snapshot, never mistake the new cache for a rollback artifact.
printf new-rpm >"$output_rpm"
sha256sum "$output_rpm" | awk '{{print $1}}' >"$output_checksum"
printf '%s\n' "$new_manifest" >"$output_manifest"
FIXTURE_CACHED_NEVRA=$target_nevra

case $SCENARIO in
  native-cvs)
    modinfo() {{ printf '%s\n' Y; }}
    [[ $(required_dkms_modules fixture-kernel) == ipu7-drivers ]]
    mkdir -p "$FIXTURE_ROOT/sys-module/intel_cvs"
    : >"$FIXTURE_ROOT/sys-module/intel_cvs/taint"
    ! camera_modules_loaded
    ;;
  external-cvs)
    modinfo() {{ return 1; }}
    [[ $(required_dkms_modules fixture-kernel) == $'ipu7-drivers\nvision-drivers' ]]
    ;;
  loaded-external-cvs-native-on-disk)
    modinfo() {{ printf '%s\n' Y; }}
    mkdir -p "$FIXTURE_ROOT/sys-module/intel_cvs"
    printf 'OE\n' >"$FIXTURE_ROOT/sys-module/intel_cvs/taint"
    camera_modules_loaded
    ;;
  retained)
    prepare_rollback "manifest=$old_manifest"
    rollback=$(rollback_rpm "manifest=$old_manifest")
    [[ $(<"$rollback") == old-rpm ]]
    ;;
  missing-before-start)
    find "$rollback_root" -depth -delete
    prepare_rollback "manifest=$old_manifest"
    ;;
  multi-invocation)
    # Marker/exposure boundary: begin_transaction persists a checksummed marker
    # while the exact old RPM is still installed and recoverable.
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    info=$(transaction_info)
    grep -Fqx "previous=manifest=$old_manifest" <<<"$info"
    grep -Fqx "previous_nevra=$FIXTURE_INSTALLED_NEVRA" <<<"$info"
    grep -Fqx "target=$target_identity" <<<"$info"
    grep -Fqx "target_nevra=$target_nevra" <<<"$info"

    # DNF boundary in the next invocation: service-enable state is irrelevant.
    # The durable marker still recovers the old identity and exact old RPM after
    # the installed identity has switched to the target.
    FIXTURE_INSTALLED_IDENTITY=$target_identity
    info=$(transaction_info)
    grep -Fqx "previous=manifest=$old_manifest" <<<"$info"
    rollback=$(rollback_rpm "manifest=$old_manifest")
    [[ $(<"$rollback") == old-rpm ]]

    # DKMS boundaries: both the changing invocation and a same-boot resumed
    # invocation after SIGKILL (changed=0) must defer while old modules are
    # loaded. Only a proven later boot satisfies that boundary.
    loaded_transaction_needs_reboot 1 true true false false
    loaded_transaction_needs_reboot 0 true true false false
    ! loaded_transaction_needs_reboot 0 true true true false
    ! loaded_transaction_needs_reboot 0 false true false false
    reboot_marker=$state_dir/reboot-required
    write_reboot_marker "$reboot_marker" boot-a dkms-target
    [[ $(reboot_marker_state "$reboot_marker" boot-a dkms-target) == current ]]
    [[ $(reboot_marker_state "$reboot_marker" boot-b dkms-target) == previous ]]
    ;;
  missing-on-resume)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    find "$rollback_root" -depth -delete
    transaction_info
    ;;
  guarded-build)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    rollback_before=$(sha256sum "$(rollback_rpm "manifest=$old_manifest")" | awk '{{print $1}}')
    [[ $(guard_unresolved_build "$new_manifest") == "$target_nevra" ]]
    rollback_after=$(sha256sum "$(rollback_rpm "manifest=$old_manifest")" | awk '{{print $1}}')
    [[ $rollback_before == "$rollback_after" ]]
    ;;
  changed-build-inputs)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    changed_manifest=$(printf 'c%.0s' {{1..64}})
    guard_unresolved_build "$changed_manifest"
    ;;
  cross-bundle-recovery)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    bundle_version=2.0.0.xps1
    # A restored old RPM must select the hashed DKMS source trees belonging to
    # that RPM's VERSION, even if similarly named trees for today's desired
    # bundle also exist. This is the post-rollback validate/commit lookup path.
    installed_dkms="$FIXTURE_INSTALLED_VERSION.input${{old_manifest:0:16}}"
    desired_dkms=$(dkms_version_for_manifest "$old_manifest")
    install -d \
      "$dkms_source_root/ipu7-drivers-$installed_dkms" \
      "$dkms_source_root/vision-drivers-$installed_dkms" \
      "$dkms_source_root/ipu7-drivers-$desired_dkms" \
      "$dkms_source_root/vision-drivers-$desired_dkms"
    [[ $(installed_dkms_version) == "$installed_dkms" ]]
    [[ $installed_dkms != "$desired_dkms" ]]
    info=$(transaction_info)
    grep -Fqx "previous=manifest=$old_manifest" <<<"$info"
    grep -Fqx "previous_nevra=$FIXTURE_INSTALLED_NEVRA" <<<"$info"
    grep -Fqx "target=$target_identity" <<<"$info"
    grep -Fqx "target_nevra=$target_nevra" <<<"$info"
    rollback=$(rollback_rpm "manifest=$old_manifest")
    [[ $(<"$rollback") == old-rpm ]]
    ;;
  cross-bundle-new-inputs)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    bundle_version=2.0.0.xps1
    transaction_info >/dev/null
    changed_manifest=$(printf 'd%.0s' {{1..64}})
    guard_unresolved_build "$changed_manifest"
    ;;
  corrupt-marker)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    printf 'corruption\n' >>"$transaction_marker"
    transaction_info
    ;;
  structurally-invalid-marker)
    begin_transaction "manifest=$old_manifest" "$target_identity" "$target_nevra"
    sed -i 's/^target_nevra=.*/target_nevra=xps-ipu7-camera-stack-invalid/' "$transaction_marker"
    head -n 4 "$transaction_marker" >"$transaction_marker.payload"
    checksum=$(sha256sum "$transaction_marker.payload" | awk '{{print $1}}')
    printf 'checksum=%s\n' "$checksum" >>"$transaction_marker.payload"
    mv -f "$transaction_marker.payload" "$transaction_marker"
    transaction_info
    ;;
  *) exit 64 ;;
esac
"""


def run(scenario: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="cybexos-camera-transaction.") as temporary:
        environment = os.environ.copy()
        environment.update(FIXTURE_ROOT=temporary, SCENARIO=scenario)
        return subprocess.run(
            ["bash", "-c", fixture_script()],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )


retained = run("retained")
assert retained.returncode == 0, (retained.returncode, retained.stdout, retained.stderr)
assert "ROLLBACK_READY manifest=" in retained.stdout

missing = run("missing-before-start")
assert missing.returncode != 0, "a missing rollback snapshot opened the DNF gate"

multi = run("multi-invocation")
assert multi.returncode == 0, (multi.returncode, multi.stdout, multi.stderr)

guarded = run("guarded-build")
assert guarded.returncode == 0, (guarded.returncode, guarded.stdout, guarded.stderr)

cross_bundle = run("cross-bundle-recovery")
assert cross_bundle.returncode == 0, (
    cross_bundle.returncode,
    cross_bundle.stdout,
    cross_bundle.stderr,
)

for scenario in (
    "missing-on-resume",
    "changed-build-inputs",
    "cross-bundle-new-inputs",
    "corrupt-marker",
    "structurally-invalid-marker",
):
    rejected = run(scenario)
    assert rejected.returncode != 0, f"{scenario} opened a resumed transaction"

print("camera rollback and multi-invocation transaction fixtures passed")

for scenario in ("native-cvs", "external-cvs", "loaded-external-cvs-native-on-disk"):
    selected = run(scenario)
    assert selected.returncode == 0, (scenario, selected.stdout, selected.stderr)
print("camera native/external CVS ownership fixtures passed")
