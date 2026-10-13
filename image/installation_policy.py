"""Fresh-install policy shared by the ISO and the checkout installer.

The inventory supplies application and security defaults. Machine identity
and verified disk encryption are inputs, never properties of the build host.
Existing saved choices are applied separately and must not be reset here.
"""
import yaml


BOOLEANS = ('manage_system_identity', 'manage_personal_dotfiles', 'cleanup_legacy_xps_artifacts',
            'passwordless_wheel', 'passwordless_local_polkit', 'docker_sudoless', 'desktop_autologin',
            'start_optional_hardware_services', 'allow_insecure_sccache_transport', 'xps_2026_camera_enabled')
FEATURES = ('developer_tools', 'connected_widgets', 'proprietary_apps', 'tailscale', 'docker', 'podman',
            'steam', 'private_hooks', 'apple_display', 'source_builds', 'local_network_services')


def defaults(inventory, *, fresh_account=True, encrypted=False):
    values = yaml.safe_load(inventory.read_text())
    if not isinstance(values, dict) or not isinstance(values.get('features'), dict):
        raise ValueError('Installation defaults must contain the feature contract')
    features = values['features']
    if set(features) != set(FEATURES):
        raise ValueError('Installation feature keys must match both installer schemas')
    for key in FEATURES:
        if type(features.get(key)) is not bool:
            raise ValueError(f'features.{key} must have a boolean installation default')
    for key in BOOLEANS:
        # The inventory retains the legacy gdm_autologin template for direct
        # Ansible callers; fresh installers use verified encryption instead.
        if key != 'desktop_autologin' and type(values.get(key)) is not bool:
            raise ValueError(f'{key} must have a boolean installation default')
    result = {key: values.get(key) is True for key in BOOLEANS}
    # Match the ISO: installed identity remains owned by Fedora/Anaconda;
    # a fresh account receives personal defaults and encrypted-root autologin.
    # Repairing an older installation must never opt it into either choice.
    result['manage_system_identity'] = False
    result['manage_personal_dotfiles'] = fresh_account and values.get('manage_personal_dotfiles') is True
    result['desktop_autologin'] = fresh_account and encrypted is True
    result['features'] = {key: features[key] for key in FEATURES}
    return result
