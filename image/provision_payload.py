"""Install the reviewed shared provisioning sources, excluding personal state."""
import shutil


def prepare_provision(root, payload):
    destination = payload / 'usr/share/cybexos/provision'
    for relative in ('image/provision.yml', 'image/provision.cfg', 'inventory/group_vars/all.yml',
                     'roles/base', 'roles/xps-2026', 'roles/apps/tasks/mpv.yml',
                     'roles/apps/tasks/voxtype-backend.yml', 'roles/apps/handlers/main.yml',
                     'roles/dotfiles/tasks/shell-defaults.yml',
                     'roles/dotfiles/files/fish-config.fish',
                     'roles/dotfiles/tasks/environment.yml', 'roles/dotfiles/templates/environment.conf.j2',
                     'roles/dotfiles/tasks/personal.yml', 'roles/dotfiles/files/kitty.conf',
                     'roles/dotfiles/files/manage-firefox-policy',
                     'roles/dotfiles/tasks/agent-skills.yml', 'scripts/manage-agent-skills',
                     'roles/desktop/tasks/portals.yml'):
        source = root / relative
        paths = sorted(source.rglob('*')) if source.is_dir() else [source]
        for path in paths:
            if not path.is_file() or path.is_symlink() or '__pycache__' in path.parts or path.suffix == '.pyc':
                continue
            target = destination / path.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            target.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
