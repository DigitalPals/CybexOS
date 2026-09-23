"""Portable desktop policy shared with the workstation; no host-home inputs."""
import json
from pathlib import Path
import shutil


def prepare_defaults(root, payload, environment, inventory):
    contract = json.loads((root / "assets/desktop-contract.json").read_text())
    vendor = payload / "usr/share/cybexos"
    seed = vendor / "user-seed"
    config = seed / ".config/cybexos"
    config.mkdir(parents=True, exist_ok=True)
    (config / "shell.json").write_text(json.dumps(contract["shell"], indent=2) + "\n")
    shutil.copytree(root / "assets/wallpapers", seed / "Pictures/Wallpapers", dirs_exist_ok=True)
    shutil.copy2(root / "assets/desktop-contract.json", vendor / "desktop-contract.json")
    shutil.copy2(root / "assets/PROVENANCE.json", vendor / "artwork-provenance.json")
    # Use the same MIME policy, including T3's OAuth callback, as Ansible.
    mime = environment.from_string((root / "roles/dotfiles/templates/mimeapps.list.j2").read_text())
    (seed / ".config/mimeapps.list").write_text(mime.render(features=inventory["features"]))

    theme = payload / "usr/share/plymouth/themes/cybex"
    theme.mkdir(parents=True, exist_ok=True)
    for file in (root / "roles/boot/files").iterdir():
        if file.is_file() and not file.is_symlink():
            shutil.copy2(file, theme / file.name)
    # Fail packaging when an image referred to by the shared script is absent.
    import re
    for name in re.findall(r'Image\("([^"/]+)"\)', (theme / "cybex.script").read_text()):
        if not (theme / name).is_file():
            raise FileNotFoundError(f"Incomplete Plymouth artwork: {name}")
    hardening = payload / "usr/lib/sysctl.d/60-cybexos-hardening.conf"
    hardening.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "roles/base/files/60-cybexos-hardening.conf", hardening)
    firewall = payload / "usr/lib/firewalld/zones/cybexos.xml"
    firewall.parent.mkdir(parents=True, exist_ok=True)
    firewall.write_text(environment.from_string(
        (root / "roles/base/templates/cybexos-zone.xml.j2").read_text()
    ).render(features=inventory["features"], firewall_ports=inventory["firewall_ports"]))
    return contract


def split_seed(vendor, contract):
    """Move small session defaults out of the expensive toolchain seed.

    User init merges both trees without replacing personal files. No personal
    plugins, tokens, identities, monitor overrides or runtime state are inputs.
    """
    seed = vendor / "user-seed"
    for name, paths in (("essential-seed", contract["essentialPaths"]),
                        ("final-seed", contract.get("activationPaths", []))):
        target = vendor / name
        target.mkdir(parents=True, exist_ok=True)
        for relative in paths:
            path = Path(relative)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"Invalid desktop seed path: {relative}")
            source = seed / path
            if source.exists() or source.is_symlink():
                destination = target / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(source, destination)
    # Record seed size during packaging, avoiding a whole-toolchain traversal
    # on the critical path to every login.
    total = sum(file.stat().st_size for tree in (seed, vendor / "final-seed") for file in tree.rglob("*")
                if file.is_file() and not file.is_symlink())
    (vendor / "seed-groups.json").write_text(json.dumps({"totalBytes": total}) + "\n")
    return total
