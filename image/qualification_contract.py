"""Versioned completed-evidence contract for QEMU producers and release admission.

This is an evidence inventory, not a substitute for executing the guest checks.
Artifact SHA-256 identities and same-source checkout parity remain mandatory.
"""
import re

SCHEMA = 1
FRESH_SCENARIOS = frozenset(('encrypted-us', 'plain-us', 'encrypted-nl', 'plain-nl'))
BASE = frozenset(('graphical-installer', 'unused-disk-unchanged', 'installed-boot-without-iso',
                  'desktop-parity', 'selected-locale-timezone-keyboard', 'live-cleanup',
                  'selinux-enforcing'))
LOGIN = frozenset((
    'initial-encrypted-keyring-unlocked-without-prompt',
    'synthetic-keyring-secret-survives-cold-reboot',
    'missing-cached-password-preserves-locked-encrypted-keyring',
    'fallback-password-login-unlocks-existing-keyring',
    'first-autologin-launch-failure-consumes-boot-attempt',
    'failed-first-autologin-manager-restart-requires-authentication',
    'failed-first-autologin-password-login-recovers-desktop',
    *(action + suffix for action in ('logout', 'compositor-crash', 'manager-restart')
      for suffix in ('-requires-authentication', '-password-recovery-and-keyring')),
))
PUBLIC_UPDATE = frozenset((
    'public-updater-committed', 'public-updater-interrupted-after-apply',
    'public-updater-pre-login-recovery', 'public-updater-second-boot-settled',
    'public-updater-root-package-vendor-restored', 'public-updater-personal-data-preserved',
    'public-updater-no-surviving-workers',
    'provisioning-cgroup-timeout-drains-detached-workers',
))


def required_checks(scenario, kind, boot_entry='install'):
    if not isinstance(scenario, str) or not isinstance(kind, str):
        raise ValueError('Qualification scenario and kind must be strings')
    if scenario not in FRESH_SCENARIOS | {'encrypted-de', 'plain-de'} or kind not in ('fresh', 'upgrade'):
        raise ValueError('Unknown qualification scenario or kind')
    encrypted = scenario.startswith('encrypted-')
    result = BASE | ({'encrypted-installation', 'encrypted-btrfs', 'autologin'} if encrypted else
                     {'plain-installation', 'plain-btrfs', 'password-login'})
    if kind == 'upgrade':
        if scenario != 'encrypted-us':
            raise ValueError('Public updater qualification requires the existing encrypted-us guest')
        return result | {'installed-rpm-upgrade', 'recovery-boot-restore'} | PUBLIC_UPDATE
    session = 'installation-only-session' if boot_entry == 'install' else 'live-boot-and-offline-applications'
    return result | {session, 'sudo-requires-password'} | (LOGIN if encrypted else set())


def validate(report):
    if (type(report.get('evidence_schema')) is not int or report['evidence_schema'] != SCHEMA
            or report.get('execution_mode') != 'qemu'
            or report.get('network') != 'outbound-blocked'
            or report.get('firmware') not in ('uefi', 'bios')
            or report.get('boot_entry') not in ('install', 'live')
            or type(report.get('legacy_installer')) is not bool):
        raise ValueError('Unsupported qualification evidence schema or execution mode')
    kind = report.get('qualification_kind')
    if kind == 'fresh' and (report.get('legacy_installer') is not False
                            or report.get('candidate_rpm_sha256') is not None):
        raise ValueError('Fresh qualification must execute the current default installer')
    if kind == 'upgrade' and not re.fullmatch(r'[0-9a-f]{64}', str(report.get('candidate_rpm_sha256', ''))):
        raise ValueError('Upgrade qualification must bind the exact candidate RPM')
    for key, pattern in (('iso_sha256', r'[0-9a-f]{64}'), ('source_revision', r'[0-9a-f]{40,64}'),
                         ('source_content_sha256', r'[0-9a-f]{64}')):
        if not isinstance(report.get(key), str) or not re.fullmatch(pattern, report[key]):
            raise ValueError('Qualification must identify the exact artifact/source digest: ' + key)
    checks = report.get('checks')
    if (not isinstance(checks, list) or not all(isinstance(item, str) for item in checks)
            or len(checks) != len(set(checks))):
        raise ValueError('Qualification checks must be distinct completed check names')
    missing = required_checks(report.get('scenario'), kind, report['boot_entry']) - set(checks)
    if missing:
        raise ValueError('Qualification is missing required scenario evidence: ' + ', '.join(sorted(missing)))
    if report.get('status') != 'passed':
        raise ValueError('Every qualification report must have passed')
