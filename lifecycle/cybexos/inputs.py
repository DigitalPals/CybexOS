"""Lock ownership: upstream, vendor graph, and unrelated personal inputs."""
import re
from .common import Failure


def root_inputs(lock):
    return lock['nodes'][lock['root']]['inputs']


def resolved(lock, name):
    value = root_inputs(lock)[name]
    if not isinstance(value, str):
        raise Failure(f'{name} must be an independently locked root input')
    return lock['nodes'][value]


def validate_machine(lock, branch='nixos-26.05'):
    upstream, vendor = resolved(lock, 'nixpkgs'), resolved(lock, 'cybexos')
    original = upstream['original']
    if original != {'type': 'github', 'owner': 'NixOS', 'repo': 'nixpkgs', 'ref': branch}:
        raise Failure('Upstream must follow the selected supported stable NixOS branch; major upgrades are deliberate.')
    if vendor['inputs'].get('nixpkgs') != ['nixpkgs']:
        raise Failure('Cybex OS must follow the machine nixpkgs input')
    selected = vendor.get('locked', {})
    origin = vendor.get('original', {})
    if selected.get('type') == 'github':
        if (origin.get('type') != 'github' or origin.get('owner') != 'DigitalPals'
                or origin.get('repo') != 'CybexOS' or set(origin) != {'type', 'owner', 'repo', 'rev'}
                or selected.get('owner') != 'DigitalPals' or selected.get('repo') != 'CybexOS'
                or not re.fullmatch('[0-9a-f]{40}', origin.get('rev', ''))
                or selected.get('rev') != origin['rev']
                or not re.fullmatch(r'sha256-[A-Za-z0-9+/]{43}=', selected.get('narHash', ''))):
            raise Failure('Cybex OS must be pinned to an exact release revision and content identity')
    elif selected.get('type') != 'path' or not selected.get('narHash'):
        raise Failure('Unsupported vendor source; development paths must be content addressed')
    nixpkgs_nodes = [v for v in lock['nodes'].values() if v.get('locked', {}).get('repo') == 'nixpkgs']
    if len(nixpkgs_nodes) != 1:
        raise Failure('Duplicate Nixpkgs inputs are prohibited; personal dependencies must follow machine nixpkgs.')


def identity(lock, name):
    node = resolved(lock, name)
    return node['locked']


def graph(lock, name):
    """Names and content under an input, leaving follows references external."""
    result = {}
    def visit(node):
        if node in result:
            return
        result[node] = lock['nodes'][node]
        for child in result[node].get('inputs', {}).values():
            if isinstance(child, str):
                visit(child)
    visit(root_inputs(lock)[name])
    return result


def unchanged_graph(old, new, name):
    # Nix may rename a graph's node IDs; compare its structural identities.
    def normalize(lock, value):
        if isinstance(value, list):
            return {'follows': value}
        node = lock['nodes'][value]
        return {k: v for k, v in node.items() if k != 'inputs'} | {
            'inputs': {k: normalize(lock, v) for k, v in node.get('inputs', {}).items()}}
    return normalize(old, root_inputs(old)[name]) == normalize(new, root_inputs(new)[name])


def validate_delta(old, new, scope):
    validate_machine(new)
    if set(root_inputs(old)) != set(root_inputs(new)):
        raise Failure('Update changed the set of personal inputs')
    allowed = {'upstream': {'nixpkgs'}, 'cybexos': {'cybexos'}, 'both': {'nixpkgs', 'cybexos'}, 'local': set()}[scope]
    for name in root_inputs(old):
        if name not in allowed and not unchanged_graph(old, new, name):
            raise Failure(f'Update unexpectedly refreshed {name}; staged configuration rejected')
