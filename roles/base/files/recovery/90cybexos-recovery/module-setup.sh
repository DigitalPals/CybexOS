#!/usr/bin/bash
# Boot a read-only CybexOS recovery point with a disposable in-memory overlay.
# Included through dracut.conf.d; inert unless cybexos.recovery= is present.

check() {
    require_kernel_modules overlay || return 1
    return 255
}

depends() {
    echo base
}

installkernel() {
    hostonly='' instmods overlay
}

install() {
    local helper
    inst_multiple mount umount mkdir sed grep cp chmod
    # A recovery point from an older release carries an older helper. The
    # installed one travels in the initramfs so restore is always available.
    for helper in /usr/local/libexec/cybexos-system-snapshot /usr/libexec/cybexos-system-snapshot; do
        if [ -x "$helper" ]; then
            inst_simple "$helper" /usr/lib/cybexos-recovery/cybexos-system-snapshot
            break
        fi
    done
    # shellcheck disable=SC2154 # dracut defines moddir for module-setup.sh.
    inst_hook pre-pivot 10 "$moddir/cybexos-recovery-overlay.sh"
}
