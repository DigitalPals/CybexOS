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


# blockinfile's rendering of the workstation's managed Kitty include
# (roles/dotfiles/tasks/personal.yml), so provisioning a seeded account finds
# its block already present instead of appending a second one.
KITTY_INCLUDE = "# BEGIN CYBEXOS MANAGED INCLUDE\ninclude cybexos.conf\n# END CYBEXOS MANAGED INCLUDE\n"


def prepare_session(root, payload, inventory):
    """Session pieces the workstation installs per user, packaged once.

    The seed is copied into a home only where a file is absent, so the
    vendor Kitty settings live in the managed fragment that provisioning
    keeps current; the seeded kitty.conf only includes it and is the user's.
    """
    vendor = payload / "usr/share/cybexos"
    kitty = vendor / "user-seed/.config/kitty"
    kitty.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / "roles/dotfiles/files/kitty.conf", kitty / "cybexos.conf")
    (kitty / "kitty.conf").write_text(KITTY_INCLUDE)
    prepare_system_session(root, payload, inventory)


def prepare_system_session(root, payload, inventory):
    """The system-wide session files; image/repair-installed stages these too."""
    vendor = payload / "usr/share/cybexos"
    # Provisioning links every account's agent skill slots to this copy.
    skills = vendor / "agent-skills/cybexos"
    if skills.exists():
        shutil.rmtree(skills)
    shutil.copytree(root / "agent-skills/cybexos", skills)
    # The workstation's user unit renders the same features. Installed
    # systems apply their saved choice in a drop-in (image/provision.yml).
    features = inventory["features"]
    unit = payload / "usr/lib/systemd/user/quickshell.service"
    unit.parent.mkdir(parents=True, exist_ok=True)
    unit.write_text(
        "[Unit]\nDescription=Quickshell desktop shell\nPartOf=hyprland-session.target\n\n"
        "[Service]\nExecStart=/usr/share/cybexos/bin/cybexos-runtime exec quickshell\n"
        f"Environment=CYBEXOS_CONNECTED_WIDGETS={int(bool(features['connected_widgets']))}\n"
        f"Environment=CYBEXOS_DEVELOPER_TOOLS={int(bool(features['developer_tools']))}\n"
        "Restart=on-failure\nRestartSec=2\n\n[Install]\nWantedBy=hyprland-session.target\n")
    # XPS hardware only: the unit starts when the session exports
    # CYBEXOS_XPS_2026=1 from /etc/cybexos/hardware.json.
    watcher = payload / "usr/libexec/cybexos-external-monitor-toggle"
    watcher.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / "roles/dotfiles/templates/external-monitor-toggle.j2", watcher)
    watcher.chmod(0o755)


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
