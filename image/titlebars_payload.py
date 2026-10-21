"""The same pinned native titlebars recipe for checkout and RPM installations."""
import hashlib
import json
from pathlib import Path
import shutil


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare_recipe(root, destination, inventory):
    """Stage the checkout role's exact helper, pin, patch and update units."""
    files = root / 'roles/desktop/files'
    recipe = destination / 'usr/share/cybexos/titlebars'
    recipe.mkdir(parents=True, exist_ok=True)
    pin = {key: inventory['titlebars_' + key] for key in ('version', 'commit', 'checksum')}
    (recipe / 'source.json').write_text(json.dumps(pin, sort_keys=True, indent=2) + '\n')
    shutil.copyfile(files / 'titlebars-native.patch', recipe / 'native.patch')
    helper = destination / 'usr/libexec/cybexos-titlebars-install'
    helper.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(files / 'titlebars-install', helper)
    helper.chmod(0o755)
    units = destination / 'usr/lib/systemd/system'
    units.mkdir(parents=True, exist_ok=True)
    for suffix in ('service', 'path'):
        shutil.copyfile(files / ('titlebars-build.' + suffix), units / ('cybexos-titlebars-build.' + suffix))


def prepare_titlebars(root, build, payload):
    """Admit only a complete native build made with this source's recipe."""
    import yaml
    inventory = yaml.safe_load((root / 'inventory/group_vars/all.yml').read_text())
    staged = build / 'titlebars-root'
    manifest_path = staged / 'usr/lib64/cybexos/titlebars.json'
    manifest = json.loads(manifest_path.read_text())
    if json.loads((build / 'titlebars.json').read_text()) != manifest:
        raise RuntimeError('Native titlebar artifact manifest differs from the staged build')
    recipe = staged / 'usr/share/cybexos/titlebars'
    pin = {key: inventory['titlebars_' + key] for key in ('version', 'commit', 'checksum')}
    inputs = manifest['inputs']
    if (inputs['source'] != pin or inputs['recipe_sha256'] != sha256(root / 'roles/desktop/files/titlebars-install')
            or inputs['patch_sha256'] != sha256(root / 'roles/desktop/files/titlebars-native.patch')
            or sha256(recipe / 'source.tar.gz') != pin['checksum'].removeprefix('sha256:')
            or sha256(staged / 'usr/lib64/cybexos/titlebars.so') != manifest['plugin_sha256']):
        raise RuntimeError('Native titlebar build does not match this source revision')
    for name in ('LICENSE', 'LICENSE.MIT'):
        if sha256(staged / 'usr/share/licenses/cybexos-titlebars' / name) != manifest['licenses'][name]:
            raise RuntimeError('Native titlebar license missing or altered: ' + name)
    for relative in ('usr/lib64/cybexos', 'usr/share/licenses/cybexos-titlebars', 'usr/share/cybexos/titlebars'):
        shutil.copytree(staged / relative, payload / relative, dirs_exist_ok=True)
    # Refresh helper/units from the source, independent of any staged contents.
    prepare_recipe(root, payload, inventory)
    return manifest
