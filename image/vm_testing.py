"""Explicitly invoked QEMU qualification support; safe to import in source checks."""
import ctypes
import os
import re
import signal
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import time

from build_support import SAFE_NAME, atomic_json, prepare_firmware, validate_qemu_path, verify_sidecar
from qmp_control import Qmp, type_text


# Virtio block identifiers are limited to 20 bytes in the guest protocol.
QUALIFICATION_DISK_SERIAL = "CYBEXOS-QUALIFY"
QUALIFICATION_UNUSED_SERIAL = "CYBEXOS-UNUSED"


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def audit_script():
    """Stream the checkout's reviewed helper to the guest; never run it here."""
    helper = Path(__file__).resolve().parents[1] / "tests/lib/quickshell-live"
    return ("set -euo pipefail\nexport XDG_RUNTIME_DIR=/run/user/$(id -u)\n"
            + helper.read_text() + "\nqs_live_begin\nqs_live_end\n")


OFFLINE_APPLICATION_AUDIT = r"""
import hashlib
import json
import ctypes
import os
import signal
from pathlib import Path
import shutil
import subprocess

home = Path.home()
os.environ['PATH'] = ':'.join(str(home / path) for path in (
    '.cargo/bin', '.local/bin', '.npm-global/bin', 'Android/Sdk/platform-tools',
)) + ':/usr/local/bin:/usr/bin'
manifest = json.loads(Path('/usr/share/cybexos/applications.json').read_text())
subprocess.run(['rpm', '-q', *manifest['packages']], check=True, stdout=subprocess.DEVNULL)
for app in manifest['flatpaks']:
    subprocess.run(['flatpak', 'info', '--system', app], check=True, stdout=subprocess.DEVNULL)
for command in ('cybex', 'fastfetch', 'claude', 'opencode', 'codex', 'cargo', 'rustup',
                'node', 'npm', 'bun', 'lazygit', 'lazydocker', 'balena', 'mdview',
                'awww', 'wayfreeze', 'voxtype', 'localsend', 't3code-desktop', 'adb'):
    assert shutil.which(command), 'Missing offline command: ' + command
for command in ('cybex', 'fastfetch', 'claude', 'opencode', 'codex', 'cargo', 'node', 'bun', 'awww', 'wayfreeze', 'voxtype'):
    result = subprocess.run([command, '--version'], check=True, capture_output=True, text=True, timeout=30)
    print(command + ': ' + (result.stdout or result.stderr).splitlines()[0])
subprocess.run(['nvim', '--headless', '+qa'], check=True, timeout=30)
sdk = home / 'Android/Sdk'
assert (sdk / 'cmdline-tools/latest/bin/sdkmanager').is_file()
subprocess.run([str(sdk / 'cmdline-tools/latest/bin/sdkmanager'), '--version'], check=True, timeout=30)
assert list((sdk / 'platforms').glob('*/android.jar'))
assert list((sdk / 'build-tools').glob('*/aapt2'))
t3 = home / '.local/share/t3code-nightly'
with (t3 / 'T3-Code-Nightly-x86_64.AppImage').open('rb') as stream:
    assert hashlib.file_digest(stream, 'sha256').hexdigest() == (t3 / 'digest').read_text().strip()
assert (home / '.local/share/voxtype/models/ggml-base.bin').is_file()
assert (home / '.local/state/cybexos/offline-apps-seeded').is_file()
if not Path('/run/cybexos-live').exists():
    import pwd
    assert pwd.getpwuid(os.getuid()).pw_shell == '/usr/bin/fish'
    assert Path('/etc/cybexos/hardware.json').is_file()
    for unit in ('hyprpolkitagent', 'hypridle', 'voxtype'):
        subprocess.run(['systemctl', '--user', 'is-active', unit], check=True)
    for unit in ('tuned-ppd', 'fwupd-refresh.timer', 'cybexos-hardware-setup.timer'):
        subprocess.run(['systemctl', 'is-enabled', unit], check=True)
    aliases = subprocess.check_output(['fish', '-ic', 'functions codex claude'], text=True)
    assert '--dangerously-bypass-approvals-and-sandbox' in aliases
    assert '--dangerously-skip-permissions' in aliases
print('Complete application manifest and offline user toolchains passed.')
"""


def require_test_iso(iso):
    original = Path(iso)
    iso = original.resolve(strict=True)
    if original.is_symlink() or not iso.is_file() or iso.suffix != ".iso" or Path("/data/pxe/iso") not in iso.parents:
        raise ValueError("Completed testing ISOs must be published under /data/pxe/iso before boot qualification")
    if not SAFE_NAME.fullmatch(iso.name):
        raise ValueError("Testing ISO filenames must use ASCII without spaces")
    verify_sidecar(iso)
    return iso


def stop_with_harness():
    # QEMU has its own process group so cleanup can flush it after Ctrl-C.
    # Linux still terminates it if the harness process is killed.
    ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)


class TestVM:
    """Own exactly one disposable virtual disk; never attach host block devices."""
    def __init__(self, work, firmware="uefi", memory=16384, guard_disk=False):
        self.work = validate_qemu_path(Path(work).resolve())
        self.firmware = firmware
        self.memory = memory
        self.guard_disk = guard_disk
        self.owned = False
        self.process = None
        self.console = None
        self.ssh = None
        self.port = free_port()
        self.vnc_port = free_port()
        self.disk = self.work / "installed.qcow2"
        self.unused_disk = self.work / "unused.qcow2"
        self.key = self.work / "id_ed25519"
        self.ssh_ready = False
        self.qmp_path = self.work / "qmp.sock"

    def screen_text(self):
        """Read a disposable guest screenshot; never retain password entry frames."""
        if not shutil.which("tesseract"):
            raise RuntimeError("Encrypted boot qualification requires tesseract for prompt recognition")
        screenshot = self.work / "prompt.png"
        qmp = Qmp(str(self.qmp_path))
        try:
            qmp.call("screendump", {"filename": str(screenshot), "format": "png"})
            return run(["tesseract", str(screenshot), "stdout", "--psm", "11"],
                       text=True, capture_output=True, timeout=20).stdout
        finally:
            qmp.stream.close()
            qmp.socket.close()
            screenshot.unlink(missing_ok=True)

    def unlock_disk(self, password, timeout=180):
        """Type once, only after recognizing the disk-unlock prompt.

        The Cybex Plymouth theme intentionally hides its prompt text. Escape
        exposes Plymouth's text display after firmware has had time to finish.
        Failing recognition is safer than typing the boot secret into a desktop.
        """
        start = time.monotonic()
        escaped = False
        while time.monotonic() - start < timeout:
            self.alive()
            if self.qmp_path.exists():
                if is_disk_prompt(self.screen_text()):
                    self.type(password + "\n")
                    return
                if not escaped and time.monotonic() - start > 20:
                    self.keypress("esc")
                    escaped = True
            time.sleep(2)
        raise RuntimeError("Disk-unlock prompt was not recognized; no password was typed")

    def prepare(self):
        for command in ("qemu-system-x86_64", "qemu-img", "ssh", "ssh-keygen", "tesseract"):
            if not shutil.which(command):
                raise RuntimeError(f"Missing VM prerequisite: {command}")
        if not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise RuntimeError("Read/write access to /dev/kvm is required")
        if self.work.exists() and any(self.work.iterdir()):
            raise ValueError("Qualification output directory must be empty")
        self.work.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.work.chmod(0o700)
        self.owned = True
        run(["qemu-img", "create", "-q", "-f", "qcow2", str(self.disk), "100G"])
        if self.guard_disk:
            run(["qemu-img", "create", "-q", "-f", "qcow2", str(self.unused_disk), "100G"])
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)])

    def start(self, iso=None, user="liveuser"):
        if self.process is not None and self.process.poll() is None:
            raise RuntimeError("Test VM is already running")
        self.qmp_path.unlink(missing_ok=True)
        self.ssh_ready = False
        self.ssh = ["ssh", "-i", str(self.key), "-p", str(self.port), "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=10", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
                    "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={self.work / 'known_hosts'}", f"{user}@127.0.0.1"]
        firmware = prepare_firmware(self.work) if self.firmware == "uefi" else []
        args = ["qemu-system-x86_64", "-no-user-config", "-name", "cybexos-qualification", "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", "4", "-m", str(self.memory),
                "-drive", f"file={self.disk},format=qcow2,if=none,id=qualification-disk,werror=report,rerror=report",
                "-device", f"virtio-blk-pci,drive=qualification-disk,serial={QUALIFICATION_DISK_SERIAL}", *firmware,
                "-device", "virtio-vga", "-device", "qemu-xhci", "-device", "usb-tablet",
                "-netdev", f"user,id=net,restrict=on,hostfwd=tcp:127.0.0.1:{self.port}-:22", "-device", "virtio-net-pci,netdev=net",
                "-vnc", f"127.0.0.1:{self.vnc_port - 5900}", "-serial", f"file:{self.work / 'serial.log'}",
                "-qmp", f"unix:{self.qmp_path},server=on,wait=off", "-monitor", "none"]
        if self.guard_disk:
            args += ["-drive", f"file={self.unused_disk},format=qcow2,if=none,id=unused-disk,werror=report,rerror=report",
                     "-device", f"virtio-blk-pci,drive=unused-disk,serial={QUALIFICATION_UNUSED_SERIAL}"]
        if iso is not None:
            args += ["-cdrom", str(require_test_iso(iso)), "-boot", "d"]
        self.console = (self.work / "qemu.log").open("a")
        self.process = subprocess.Popen(args, stdout=self.console, stderr=subprocess.STDOUT,
                                        process_group=0, preexec_fn=stop_with_harness)
        state = {"pid": self.process.pid, "ssh": self.ssh, "vnc_port": self.vnc_port, "qmp": str(self.qmp_path), "disk": str(self.disk)}
        if self.guard_disk:
            state['unused_disk'] = str(self.unused_disk)
        atomic_json(self.work / "vm.json", state)

    def alive(self):
        if self.process.poll() is not None:
            raise RuntimeError("Qualification VM exited; inspect qemu.log")

    def keypress(self, keys):
        qmp = Qmp(str(self.qmp_path))
        try:
            qmp.call("send-key", {"keys": [{"type": "qcode", "data": key} for key in keys.split("+")]})
        finally:
            qmp.stream.close()
            qmp.socket.close()

    def type(self, text):
        qmp = Qmp(str(self.qmp_path))
        try:
            type_text(qmp, text)
        finally:
            qmp.stream.close()
            qmp.socket.close()

    def wait_ssh(self, timeout=300, setup=True, setup_password=None):
        """Poll SSH readiness and bootstrap only inside a recognized terminal.

        No guest debug agent is shipped. Keyboard injection remains the transport
        for initial test access, so the deadline includes firmware/desktop startup.
        A fresh printf marker proves a shell executed before private setup input.
        """
        deadline, next_attempt, attempt = time.monotonic() + timeout, 0, 0
        desktop_observed = False
        public = self.key.with_suffix(".pub").read_text().strip()
        command = "mkdir -p ~/.ssh; printf '%s\\n' " + shlex.quote(public)
        command += " > ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; "
        root_setup = 'restorecon -RF "$HOME/.ssh"; systemctl start sshd; firewall-cmd --add-service=ssh'
        # Installed fixtures have a real password. Keep it out of argv/logs and
        # disable history in the throwaway graphical terminal before typing.
        if setup_password:
            root_setup = 'restorecon -RF /home/qualification/.ssh; systemctl start sshd; firewall-cmd --add-service=ssh'
            command += "printf '%s\\n' " + shlex.quote(setup_password) + " | sudo -k -S -p '' sh -c " + shlex.quote(root_setup)
        else:
            command += "sudo restorecon -RF ~/.ssh; sudo systemctl start sshd; sudo firewall-cmd --add-service=ssh"
        command = "HISTFILE=/dev/null; set +o history; " + command + "; exit\n"
        while time.monotonic() < deadline:
            self.alive()
            if subprocess.run([*self.ssh, "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                self.ssh_ready = True
                return
            if setup and time.monotonic() >= next_attempt and self.qmp_path.exists():
                # Typing even public shell commands at GRUB can enter its
                # editor and prevent boot. Require an actual desktop surface;
                # the installer may cover Welcome on current live images.
                if not desktop_observed:
                    screen = " ".join(self.screen_text().lower().split())
                    desktop_observed = any(phrase in screen for phrase in (
                        "make yourself at home", "welcome to your new desktop",
                        "your next workspace", "make it yours"))
                    if not desktop_observed:
                        next_attempt = time.monotonic() + 5
                        time.sleep(1)
                        continue
                # Keep the terminal away from the first-run welcome window;
                # repeated tiled terminals make the OCR marker unreadable.
                self.keypress("meta_l+9")
                self.keypress("meta_l+ret")
                time.sleep(1)
                # Installed terminals now start Fish. Enter a history-free
                # Bash before the readiness marker or any private fixture
                # input, without putting that input in a bash -c argument.
                self.type("exec env HISTFILE=/dev/null bash --noprofile --norc\n")
                time.sleep(1)
                attempt += 1
                # The contiguous marker does not occur in the typed command;
                # seeing it therefore proves that a shell ran printf.
                marker = f"CYBEXOSREADY{7319 + attempt}"
                self.type("HISTFILE=/dev/null; set +o history; printf 'CYBEXOSREADY%d\\n' $((7319 + " + str(attempt) + "))\n")
                time.sleep(1)
                if marker in re.sub(r"[^A-Z0-9]", "", self.screen_text().upper()):
                    self.type(command)
                else:
                    self.keypress("meta_l+q")
                next_attempt = time.monotonic() + 15
            time.sleep(1)
        raise RuntimeError("SSH/desktop readiness deadline exceeded; inspect VM through vm-control")

    def bootstrap_installed_ssh(self, password, timeout=120):
        """Use a verified text console, then switch its keymap to US for setup.

        This works after a plain install without desktop autologin and after a
        non-US install without guessing how punctuation maps in Hyprland.
        Passwords are typed only at a recognized login/sudo prompt.
        """
        self.keypress("ctrl+alt+f3")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if re.search(r'login\s*:', self.screen_text(), re.IGNORECASE):
                break
            self.alive()
            time.sleep(2)
        else:
            raise RuntimeError("Installed text-console login prompt was not recognized")
        self.type("qualification\n")
        self._wait_password_prompt(deadline)
        self.type(password + "\n")
        time.sleep(2)
        self.type("echo CYBEXOSTTYREADY\n")
        while time.monotonic() < deadline:
            if self.screen_text().upper().count('CYBEXOSTTYREADY') >= 2:
                break
            self.alive()
            time.sleep(1)
        else:
            raise RuntimeError("Installed text-console shell was not confirmed")
        self.type("clear\n")
        # `sudo loadkeys us` contains only letters and spaces, so its physical
        # keystrokes are stable under the supported US/NL/DE layouts.
        time.sleep(2)
        self.type("sudo loadkeys us\n")
        while time.monotonic() < deadline:
            screen = " ".join(self.screen_text().lower().split())
            if re.search(r'password\s*:|passwort\s*:|wachtwoord\s*:', screen):
                self.type(password + "\n")
                break
            # Older baseline images may already have passwordless sudo. After
            # the clear above, two prompts show that loadkeys returned.
            if screen.count('qualification@') >= 2:
                break
            self.alive()
            time.sleep(1)
        else:
            raise RuntimeError("Sudo keymap setup did not reach a prompt or return")
        time.sleep(2)
        public = self.key.with_suffix(".pub").read_text().strip()
        command = "HISTFILE=/dev/null; set +o history; mkdir -p ~/.ssh; printf '%s\\n' "
        command += shlex.quote(public) + " > ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; "
        command += "sudo -n restorecon -RF /home/qualification/.ssh; sudo -n systemctl start sshd; "
        command += "sudo -n firewall-cmd --add-service=ssh; exit\n"
        self.type(command)
        self.wait_ssh(timeout=max(15, int(deadline - time.monotonic())), setup=False)

    def _wait_password_prompt(self, deadline):
        while time.monotonic() < deadline:
            screen = " ".join(self.screen_text().lower().split())
            if re.search(r'password\s*:|passwort\s*:|wachtwoord\s*:', screen):
                return
            self.alive()
            time.sleep(1)
        raise RuntimeError("Installed password prompt was not recognized; no password was typed")

    def wait_desktop(self, timeout=120):
        deadline = time.monotonic() + timeout
        command = "XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active --quiet quickshell.service"
        while time.monotonic() < deadline:
            self.alive()
            if subprocess.run([*self.ssh, command], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                return
            time.sleep(1)
        diagnosis = subprocess.run(
            [*self.ssh, "systemctl --user status quickshell.service --no-pager; "
             "journalctl --user -b -u quickshell.service --no-pager -n 35"],
            capture_output=True, text=True, timeout=20)
        details = (diagnosis.stdout + diagnosis.stderr).strip()[-6000:]
        raise RuntimeError(f"Quickshell readiness deadline exceeded: {details}")

    def audit(self, applications=True):
        self.wait_desktop()
        run([*self.ssh, "bash -s"], input=audit_script(), text=True, timeout=45)
        if applications:
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                result = subprocess.run([*self.ssh, 'test -f ~/.local/state/cybexos/offline-apps-seeded'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result.returncode == 0:
                    break
                self.alive()
                time.sleep(2)
            else:
                raise RuntimeError("Offline application seed did not finish")
            run([*self.ssh, "python3 -"], input=OFFLINE_APPLICATION_AUDIT, text=True, timeout=300)

    def stop(self, graceful=False):
        try:
            if self.process and self.process.poll() is None and self.ssh_ready:
                run([*self.ssh, "bash -s"], input=audit_script(), text=True, timeout=45)
                run([*self.ssh, "sync"], timeout=45)
                if graceful:
                    subprocess.run([*self.ssh, "sudo systemctl poweroff"], timeout=20, check=False)
                    self.process.wait(timeout=60)
        finally:
            if self.process and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            if self.console:
                self.console.close()
            self.ssh_ready = False

    def cleanup(self, keep_artifacts=False):
        if not self.owned:
            return
        try:
            self.stop()
        finally:
            for name in ("id_ed25519", "id_ed25519.pub", "known_hosts", "vm.json", "qmp.sock", "prompt.png"):
                (self.work / name).unlink(missing_ok=True)
            if not keep_artifacts:
                for name in ("installed.qcow2", "unused.qcow2", "OVMF_VARS.fd", "OVMF_VARS.qcow2", "serial.log", "qemu.log"):
                    (self.work / name).unlink(missing_ok=True)


def is_disk_prompt(text):
    """Require an encryption context, not a generic login/keyring password box."""
    compact = " ".join(text.lower().split())
    return bool(re.search(r"(?:passphrase|password).{0,180}(?:disk|luks|volume|crypt)", compact)
                or re.search(r"(?:disk|luks|volume|crypt).{0,180}(?:passphrase|password)", compact))
