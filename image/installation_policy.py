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
# Choices an installation seed (or a factory reset's preserved selection) may
# make before the first account exists. Identity, automatic login and
# passwordless sudo are decided by the installer's own verified steps.
CHOICE_BOOLEANS = ('manage_personal_dotfiles', 'passwordless_local_polkit', 'docker_sudoless')


def choices(document):
    """Validate explicit first-account choices in the config.yml schema.

    Only CHOICE_BOOLEANS and feature switches are accepted, each a boolean;
    an absent key keeps the installation default. Raises ValueError with a
    message that names the offending key.
    """
    if document is None:
        return {}
    if not isinstance(document, dict):
        raise ValueError('config must be a mapping of installation choices')
    unknown = sorted(set(document) - set(CHOICE_BOOLEANS) - {'features'})
    if unknown:
        raise ValueError(f'config.{unknown[0]} is not a choice an installation can make')
    result = {}
    for key in CHOICE_BOOLEANS:
        if key in document:
            if type(document[key]) is not bool:
                raise ValueError(f'config.{key} must be true or false')
            result[key] = document[key]
    features = document.get('features', {})
    if not isinstance(features, dict):
        raise ValueError('config.features must be a mapping')
    unknown = sorted(set(features) - set(FEATURES))
    if unknown:
        raise ValueError(f'config.features.{unknown[0]} is not a CybexOS feature')
    for key, value in features.items():
        if type(value) is not bool:
            raise ValueError(f'config.features.{key} must be true or false')
    if features:
        result['features'] = dict(features)
    return result


def apply_choices(values, selected):
    """Return defaults with validated choices applied (a new mapping)."""
    selected = choices(selected)
    result = {**values, 'features': dict(values['features'])}
    result.update({key: value for key, value in selected.items() if key != 'features'})
    result['features'].update(selected.get('features', {}))
    # The docker group is root-equivalent; it only exists with Docker selected.
    result['docker_sudoless'] = result['docker_sudoless'] and result['features']['docker']
    return result


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
