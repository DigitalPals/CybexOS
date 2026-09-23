%post --erroronfail --log=/var/log/anaconda/cybexos-cleanup.log
set -eu
# These are exact live-image-owned paths, not user customization directories.
if getent passwd liveuser >/dev/null; then
  userdel --remove liveuser
fi
rm -f /etc/sudoers.d/cybexos-live
rm -f /etc/polkit-1/rules.d/49-cybexos-live.rules
rm -f /var/lib/AccountsService/users/liveuser
rm -f /etc/systemd/system/multi-user.target.wants/cybexos-live.service
rm -f /usr/lib/systemd/system/cybexos-live.service
rm -f /usr/libexec/cybexos-live-setup
rm -f /etc/dracut.conf.d/99-live.conf
rm -f /etc/dracut.conf.d/99-liveos.conf
rm -f /etc/ssh/ssh_host_*
cat > /etc/gdm/custom.conf <<'GDM'
[daemon]
DefaultSession=hyprland-quickshell.desktop
[security]
[xdmcp]
[chooser]
[debug]
GDM
systemctl disable sshd.service
systemctl enable gdm.service NetworkManager.service firewalld.service
systemctl set-default graphical.target
# GDM chooses its generic GNOME fallback for new users unless AccountsService
# records the intended session. Set this after Anaconda creates the accounts.
python3 - <<'PY'
import configparser
from pathlib import Path
import pwd
import subprocess
directory = Path('/var/lib/AccountsService/users')
directory.mkdir(parents=True, exist_ok=True)
for account in pwd.getpwall():
    if not (1000 <= account.pw_uid < 65534 and account.pw_dir.startswith('/home/')):
        continue
    subprocess.run(['usermod', '--append', '--groups', 'docker', account.pw_name], check=True)
    path = directory / account.pw_name
    settings = configparser.ConfigParser()
    settings.optionxform = str
    settings.read(path)
    if not settings.has_section('User'):
        settings.add_section('User')
    settings['User']['Session'] = 'hyprland-quickshell'
    settings['User']['XSession'] = 'hyprland-quickshell'
    settings['User']['SystemAccount'] = 'false'
    with path.open('w') as stream:
        settings.write(stream)
    path.chmod(0o600)
PY
restorecon -RF /etc/gdm /var/lib/AccountsService/users
%end
