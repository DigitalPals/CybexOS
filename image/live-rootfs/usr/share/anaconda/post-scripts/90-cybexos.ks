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
rm -f /usr/libexec/cybexos-installer-backend /usr/libexec/cybexos-installer-target
rm -f /usr/bin/cybexos-installer-browser
rm -rf /usr/share/cockpit/cybexos-installer
rm -f /etc/anaconda/conf.d/20-cybexos.conf
rm -f /etc/dracut.conf.d/99-live.conf
rm -f /etc/dracut.conf.d/99-liveos.conf
rm -f /etc/ssh/ssh_host_*
# Never copy a live autologin decision to the installed system. The final
# target helper can opt in only after verifying the installed encrypted root.
rm -f /run/cybexos-live-session /etc/sddm.conf
rm -f /var/lib/sddm/state.conf
install -d -m 0755 /etc/cybexos
cat > /etc/cybexos/login.json <<'LOGIN'
{"version":1,"user":"","autologin":false,"live":false}
LOGIN
chmod 0644 /etc/cybexos/login.json
systemctl disable sshd.service
systemctl enable sddm.service NetworkManager.service firewalld.service
systemctl set-default graphical.target
# Anaconda adds SSH to its selected firewall zone unless explicitly disabled.
# Restore the shipped CybexOS policy after its configuration task has finished.
install -D -m 0644 /usr/lib/firewalld/zones/cybexos.xml /etc/firewalld/zones/cybexos.xml
firewall-offline-cmd --set-default-zone=cybexos
# Retain desktop metadata for account-aware applications. SDDM's prepared
# configuration selects the shared CybexOS session independently.
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
restorecon -RF /etc/cybexos /var/lib/AccountsService/users
/usr/libexec/cybexos-seed-installed-users
# Anaconda's initial initramfs was created before this post script removed the
# live-only dracut settings. Rebuild from the final installed configuration.
dracut --force --regenerate-all
%end

%post --nochroot --erroronfail --log=/var/log/anaconda/cybexos-target-policy.log
set -eu
# Reads only the confirmed account/encryption policy from live /run. The helper
# verifies that the mounted target root is encrypted before enabling autologin.
/usr/libexec/cybexos-installer-target
%end
