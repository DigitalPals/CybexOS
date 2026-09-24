#!/usr/bin/sh
# dracut pre-pivot hook (sourced). With cybexos.recovery=<id>, the read-only
# snapshot that the kernel command line mounted at $NEWROOT becomes the lower
# layer of an overlay whose writable layer is RAM: the system boots normally,
# nothing reaches the snapshot, and every change disappears at shutdown.
# Under systemd the root is already mounted when dracut's mount hooks would
# run, so they are skipped; pre-pivot hooks always run before switch-root.

command -v getarg >/dev/null || . /lib/dracut-lib.sh

cybexos_recovery_overlay() {
    # dracut sources hooks into one shell; prefixed names avoid collisions.
    cybexos_recovery_id=$(getarg cybexos.recovery=) || return 0
    [ -n "$cybexos_recovery_id" ] || return 0
    if ! printf '%s\n' "$cybexos_recovery_id" | grep -Eqx '[0-9]{8}T[0-9]{6}Z-[0-9]+'; then
        warn "cybexos-recovery: ignoring malformed recovery point '$cybexos_recovery_id'"
        return 0
    fi
    # Overridable only so the repository tests can run this hook unprivileged.
    cybexos_recovery_base=${CYBEXOS_RECOVERY_BASE:-/run/cybexos-recovery}
    [ -e "$cybexos_recovery_base/active" ] && return 0
    if ! ismounted "$NEWROOT"; then
        warn "cybexos-recovery: $NEWROOT is not mounted; recovery overlay skipped"
        return 0
    fi
    # Moving the root would hide separately mounted parts such as /usr.
    if grep -q " $NEWROOT/" /proc/self/mounts; then
        warn "cybexos-recovery: $NEWROOT has submounts; continuing with the read-only snapshot"
        return 0
    fi
    mkdir -p "$cybexos_recovery_base/lower" "$cybexos_recovery_base/rw" || return 0
    if ! mount -t tmpfs -o mode=0755 cybexos-recovery "$cybexos_recovery_base/rw"; then
        warn 'cybexos-recovery: could not create the in-memory layer'
        return 0
    fi
    mkdir -m 0755 "$cybexos_recovery_base/rw/upper" "$cybexos_recovery_base/rw/work"
    # The kernel refuses to move a mount below a shared parent. systemd makes
    # the same change itself immediately before switching root.
    mount --make-private /
    if ! mount --move "$NEWROOT" "$cybexos_recovery_base/lower"; then
        warn 'cybexos-recovery: could not move the snapshot mount'
        umount "$cybexos_recovery_base/rw"
        return 0
    fi
    if ! mount -t overlay cybexos-recovery \
            -o "lowerdir=$cybexos_recovery_base/lower,upperdir=$cybexos_recovery_base/rw/upper,workdir=$cybexos_recovery_base/rw/work" "$NEWROOT"; then
        warn 'cybexos-recovery: overlay failed; continuing with the read-only snapshot'
        mount --move "$cybexos_recovery_base/lower" "$NEWROOT"
        umount "$cybexos_recovery_base/rw"
        return 0
    fi
    # The root line would ask systemd to remount the overlay with Btrfs
    # options. /boot and the EFI tree are the real ones, so they stay
    # read-only: a kernel installed here would outlive the boot without its
    # modules. `cybexos-system-snapshot restore` remounts /boot for itself.
    # These edits land in the RAM layer, never in the snapshot.
    if [ -f "$NEWROOT/etc/fstab" ]; then
        sed -i -E \
            -e 's@^([[:space:]]*[^#[:space:]]+[[:space:]]+/[[:space:]])@# cybexos-recovery: \1@' \
            -e 's@^([[:space:]]*[^#[:space:]]+[[:space:]]+/boot(/efi)?[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)@\1ro,\3@' \
            "$NEWROOT/etc/fstab"
    fi
    if [ -f /usr/lib/cybexos-recovery/cybexos-system-snapshot ]; then
        cp /usr/lib/cybexos-recovery/cybexos-system-snapshot "$cybexos_recovery_base/cybexos-system-snapshot"
        chmod 0755 "$cybexos_recovery_base/cybexos-system-snapshot"
    fi
    printf '%s\n' "$cybexos_recovery_id" > "$cybexos_recovery_base/active"
    info "cybexos-recovery: recovery point $cybexos_recovery_id is running with an in-memory overlay"
}

cybexos_recovery_overlay
