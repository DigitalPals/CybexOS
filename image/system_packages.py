"""Read the ISO's system and desktop package selections for checkout installs."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
LOCAL_PACKAGES = {'cybexos-desktop', 'cybexos-offline-apps', 'cybexos-offline-inputs'}
PACKAGE = re.compile(r'[A-Za-z0-9][A-Za-z0-9+_.:-]*\Z')
DEPENDENCY = re.compile(r'([A-Za-z0-9][A-Za-z0-9+_.:-]*)(?:\s*(>=|<=|=|>|<)\s*([^\s]+))?')


def contract(root=ROOT):
    kickstart = (root / 'image/live.ks').read_text()
    match = re.search(r'(?ms)^%packages([^\n]*)\n(.*?)^%end\s*$', kickstart)
    if not match or '--exclude-weakdeps' not in match[1].split():
        raise ValueError('The shared ISO package policy must explicitly exclude weak dependencies')
    packages, groups, excluded, constraints = set(), set(), set(), {}
    for raw in match[2].splitlines():
        value = raw.split('#', 1)[0].strip()
        if not value:
            continue
        if value.startswith('-') and PACKAGE.fullmatch(value[1:]):
            excluded.add(value[1:])
        elif value.startswith('@') and PACKAGE.fullmatch(value[1:]):
            groups.add(value)
        elif PACKAGE.fullmatch(value):
            if value not in LOCAL_PACKAGES:
                packages.add(value)
        else:
            raise ValueError('Unsupported ISO package selection: ' + value)
    spec = (root / 'image/cybexos-desktop.spec').read_text().split('%description', 1)[0]
    for line in spec.splitlines():
        if not line.startswith('Requires:'):
            continue
        remaining = line.split(':', 1)[1].strip()
        while remaining:
            dependency = DEPENDENCY.match(remaining)
            if not dependency:
                raise ValueError('Unsupported desktop dependency: ' + remaining)
            name, operator, version = dependency.groups()
            if name not in LOCAL_PACKAGES:
                if version and '%' in version:
                    raise ValueError('Unresolved system dependency macro')
                packages.add(name)
                if operator:
                    constraint = name + ' ' + operator + ' ' + version
                    if name in constraints and constraints[name] != constraint:
                        raise ValueError('Conflicting desktop dependency: ' + name)
                    constraints[name] = constraint
            remaining = remaining[dependency.end():].strip()
    if packages & excluded:
        raise ValueError('A system package is both selected and excluded')
    return {'packages': sorted(packages), 'groups': sorted(groups), 'excluded': sorted(excluded),
            'selectors': sorted(groups) + [constraints.get(name, name) for name in sorted(packages)],
            'install_weak_deps': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    print(json.dumps(contract(args.root)))


if __name__ == '__main__':
    main()
