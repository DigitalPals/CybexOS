"""A short-lived NetworkManager secret agent for one VPN activation.

Cybex OS runs no network applet, so when a VPN needs a password
NetworkManager finds no secret agent to ask and fails the activation with
"no secrets". For the length of one user-requested activation this module
registers a secret agent on the system bus and activates the profile from
the same process, whose agent NetworkManager asks first. It answers only
that profile's VPN secret request, by running the VPN plugin's own sign-in
dialog: the `auth-dialog` nm-applet uses, shipped by the installed
NetworkManager-*-gnome plugin. Secrets travel from the dialog's stdout
straight into the D-Bus reply. They are never logged, written to disk or
returned to the caller, and SaveSecrets is declined, so a profile keeps
whatever secret storage it was set up with.

Every other request (another profile, Wi-Fi, 802.1X, a WireGuard key) is
answered with NoSecrets, so another agent can still take it.
"""
from __future__ import annotations

import configparser
import os
from pathlib import Path
import signal
import subprocess
from typing import Any

NM_BUS = "org.freedesktop.NetworkManager"
NM_PATH = "/org/freedesktop/NetworkManager"
SETTINGS_PATH = NM_PATH + "/Settings"
AGENT_MANAGER_PATH = NM_PATH + "/AgentManager"
AGENT_PATH = NM_PATH + "/SecretAgent"
ACTIVE_INTERFACE = NM_BUS + ".Connection.Active"
AGENT_ERROR = NM_BUS + ".SecretAgent"
DEFAULT_PLUGIN_DIRS = ("/usr/lib/NetworkManager/VPN", "/etc/NetworkManager/VPN")

ALLOW_INTERACTION = 0x1
REQUEST_NEW = 0x2
CAPABILITY_VPN_HINTS = 0x1
STATE_ACTIVATED = 2
STATE_DEACTIVATED = 4

AGENT_XML = """
<node>
  <interface name="org.freedesktop.NetworkManager.SecretAgent">
    <method name="GetSecrets">
      <arg name="connection" type="a{sa{sv}}" direction="in"/>
      <arg name="connection_path" type="o" direction="in"/>
      <arg name="setting_name" type="s" direction="in"/>
      <arg name="hints" type="as" direction="in"/>
      <arg name="flags" type="u" direction="in"/>
      <arg name="secrets" type="a{sa{sv}}" direction="out"/>
    </method>
    <method name="CancelGetSecrets">
      <arg name="connection_path" type="o" direction="in"/>
      <arg name="setting_name" type="s" direction="in"/>
    </method>
    <method name="SaveSecrets">
      <arg name="connection" type="a{sa{sv}}" direction="in"/>
      <arg name="connection_path" type="o" direction="in"/>
    </method>
    <method name="DeleteSecrets">
      <arg name="connection" type="a{sa{sv}}" direction="in"/>
      <arg name="connection_path" type="o" direction="in"/>
    </method>
  </interface>
</node>
"""

# NMActiveConnectionStateReason, as NetworkManager reports why a connection
# ended. NO_SECRETS splits on what this agent saw.
REASONS = {
    2: ("vpn_disconnected", "The VPN was disconnected"),
    3: ("vpn_network_lost", "The network under the VPN went away"),
    4: ("vpn_service_stopped", "The VPN service stopped unexpectedly"),
    5: ("vpn_ip_config", "The VPN server sent settings this computer cannot use"),
    6: ("vpn_timeout", "The VPN server did not answer in time"),
    7: ("vpn_service_timeout", "The VPN service did not start in time"),
    8: ("vpn_service_failed", "The VPN service could not start. Check that its plugin is installed."),
    9: ("vpn_no_secrets", "The VPN needs a password or key that was not provided"),
    10: ("vpn_login_failed", "The VPN server rejected the sign-in"),
    11: ("vpn_missing", "That VPN connection no longer exists"),
    12: ("vpn_dependency_failed", "The connection this VPN depends on failed"),
    13: ("vpn_device_failed", "The VPN's network interface could not be created"),
    14: ("vpn_device_removed", "The VPN's network interface went away"),
}


class AgentError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def plugin_dirs() -> list[Path]:
    # The override exists for the fixture suite; the plugin directories are
    # otherwise root-owned package paths.
    override = os.environ.get("NETWORK_VPN_PLUGIN_DIRS", "")
    return [Path(item) for item in (override.split(":") if override else DEFAULT_PLUGIN_DIRS) if item]


def plugin_info(service_type: str, directories: list[Path] | None = None) -> dict[str, Any] | None:
    """The sign-in dialog a VPN plugin's .name file declares, if usable."""
    if not service_type:
        return None
    for directory in directories if directories is not None else plugin_dirs():
        try:
            entries = sorted(directory.glob("*.name"))
        except OSError:
            continue
        for entry in entries:
            parser = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                parser.read(entry, encoding="utf-8")
            except (configparser.Error, OSError, UnicodeDecodeError):
                continue
            service = parser.get("VPN Connection", "service", fallback="").strip()
            name = parser.get("VPN Connection", "name", fallback="").strip()
            # A profile may carry the plugin's short name instead of its
            # D-Bus service name.
            if service_type not in {service, name, f"{NM_BUS}.{name}"} - {""}:
                continue
            dialog = parser.get("GNOME", "auth-dialog", fallback="").strip()
            if not os.path.isabs(dialog) or not os.access(dialog, os.X_OK):
                return None
            hints = parser.get("GNOME", "supports-hints", fallback="").strip().lower() in ("true", "yes", "1")
            return {"dialog": dialog, "hints": hints}
    return None


def dialog_argv(info: dict[str, Any], connection_id: str, uuid: str, service: str,
                flags: int, hints: list[str]) -> list[str]:
    argv = [info["dialog"], "-u", uuid, "-n", connection_id, "-s", service]
    if flags & ALLOW_INTERACTION:
        argv.append("-i")
    if flags & REQUEST_NEW:
        argv.append("-r")
    if info.get("hints"):
        for hint in hints:
            argv += ["-t", hint]
    return argv


def dialog_input(data: dict[str, Any], stored: dict[str, Any]) -> bytes:
    """The profile's VPN data and any stored secrets, in the dialog protocol."""
    parts: list[str] = []
    for prefix, values in (("DATA", data), ("SECRET", stored)):
        for key, value in sorted((values or {}).items()):
            key, value = str(key), str(value)
            if "\n" not in key and "\n" not in value:
                parts.append(f"{prefix}_KEY={key}\n{prefix}_VAL={value}\n\n")
    parts.append("DONE\n\n")
    return "".join(parts).encode("utf-8")


def dialog_secrets(lines: list[str]) -> dict[str, str]:
    """The dialog prints key and value lines alternately."""
    return {lines[index]: lines[index + 1] for index in range(0, len(lines) - 1, 2) if lines[index]}


def failure_for_reason(reason: int, *, canceled: bool = False, plugin_missing: bool = False) -> tuple[str, str]:
    if reason == 9 and canceled:
        return "vpn_canceled", "The VPN sign-in was canceled"
    if reason == 9 and plugin_missing:
        return "vpn_plugin_missing", "No sign-in dialog is installed for this VPN type"
    return REASONS.get(reason, ("vpn_failed", "The VPN could not connect"))


def failure_for_dbus_error(name: str) -> tuple[str, str]:
    if name.endswith((".PermissionDenied", ".NotAuthorized", ".AccessDenied")):
        return "not_authorized", "You are not allowed to connect this VPN"
    if name.endswith(".UnknownConnection"):
        return "vpn_missing", "That VPN connection no longer exists"
    if name.endswith((".ConnectionNotActive", ".UnknownDevice")):
        return "vpn_no_network", "Connect to a network before starting the VPN"
    if name.endswith(".ServiceUnknown") or name.endswith(".NameHasNoOwner"):
        return "networkmanager_unavailable", "NetworkManager is not running"
    return "vpn_failed", "NetworkManager could not start the VPN"


class Dialog:
    """One run of a plugin's sign-in dialog for one GetSecrets call."""

    def __init__(self, argv: list[str], payload: bytes):
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, close_fds=True)
        self.lines: list[str] = []
        self.buffer = b""
        self.quit_sent = False
        os.set_blocking(self.process.stdout.fileno(), False)
        try:
            self.process.stdin.write(payload)
            self.process.stdin.flush()
        except OSError:
            pass

    def quit(self) -> None:
        # The dialog prints its secrets, then an empty line, and waits to be
        # told it may exit.
        if self.quit_sent:
            return
        self.quit_sent = True
        try:
            self.process.stdin.write(b"QUIT\n\n")
            self.process.stdin.close()
        except OSError:
            pass

    def pump(self) -> bool:
        """Read what the dialog printed; True once it has exited."""
        exited = self.process.poll() is not None
        while True:
            try:
                chunk = os.read(self.process.stdout.fileno(), 4096)
            except BlockingIOError:
                break
            except OSError:
                chunk = b""
            if not chunk:
                break
            self.buffer += chunk
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line:
                    self.lines.append(line.decode("utf-8", errors="replace"))
                else:
                    self.quit()
        return exited

    def result(self) -> tuple[bool, dict[str, str]]:
        self.pump()
        secrets = dialog_secrets(self.lines) if self.process.returncode == 0 else {}
        self.lines = []
        self.buffer = b""
        return self.process.returncode == 0, secrets

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.lines = []
        self.buffer = b""


class Activation:
    """Register, activate, answer this profile's VPN secrets, unregister."""

    def __init__(self, uuid: str, deadline: float):
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.uuid = uuid
        self.deadline = deadline
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.loop = GLib.MainLoop()
        self.outcome: tuple[bool, str, str] | None = None
        self.owner = ""
        self.connection_path = ""
        self.active_path = ""
        self.states: dict[str, tuple[int, int]] = {}
        self.dialog: Dialog | None = None
        self.invocation: Any = None
        self.canceled = False
        self.plugin_missing = False
        self.registered = False
        self.registration = 0
        self.subscription = 0
        self.ticks = 0
        self.sources: list[int] = []

    def call(self, path: str, interface: str, method: str, signature: str | None = None,
             values: tuple = (), bus_name: str = NM_BUS) -> Any:
        parameters = self.GLib.Variant(signature, values) if signature else None
        reply = self.bus.call_sync(bus_name, path, interface, method, parameters, None,
                                   self.Gio.DBusCallFlags.NONE, 10000, None)
        return reply.unpack() if reply is not None else ()

    def remote_error(self, error: Exception) -> str:
        if not isinstance(error, self.GLib.Error):
            return ""
        return self.Gio.DBusError.get_remote_error(error) or ""

    def run(self) -> None:
        GLib = self.GLib
        try:
            try:
                self.owner = self.call("/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner",
                                       "(s)", (NM_BUS,), bus_name="org.freedesktop.DBus")[0]
            except GLib.Error as error:
                raise AgentError("networkmanager_unavailable", "NetworkManager is not running") from error
            try:
                self.connection_path = self.call(SETTINGS_PATH, NM_BUS + ".Settings", "GetConnectionByUuid",
                                                 "(s)", (self.uuid,))[0]
            except GLib.Error as error:
                raise AgentError("vpn_missing", "That VPN connection no longer exists") from error
            # Subscribe before activating: a quick failure can end the
            # activation before its reply arrives here.
            self.subscription = self.bus.signal_subscribe(
                self.owner, ACTIVE_INTERFACE, "StateChanged", None, None,
                self.Gio.DBusSignalFlags.NONE, self.on_state, None)
            node = self.Gio.DBusNodeInfo.new_for_xml(AGENT_XML)
            self.registration = self.bus.register_object(AGENT_PATH, node.interfaces[0],
                                                         self.on_method, None, None)
            try:
                self.call(AGENT_MANAGER_PATH, NM_BUS + ".AgentManager", "RegisterWithCapabilities",
                          "(su)", (f"org.cybexos.network.vpn-{os.getpid()}", CAPABILITY_VPN_HINTS))
                self.registered = True
            except GLib.Error as error:
                raise AgentError("agent_failed", "NetworkManager did not accept the VPN sign-in helper") from error
            self.bus.call(NM_BUS, NM_PATH, NM_BUS, "ActivateConnection",
                          GLib.Variant("(ooo)", (self.connection_path, "/", "/")),
                          GLib.VariantType.new("(o)"),
                          self.Gio.DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                          int(self.deadline * 1000), None, self.on_activated, None)
            self.sources.append(GLib.timeout_add(int(self.deadline * 1000), self.on_deadline))
            self.sources.append(GLib.timeout_add(100, self.on_tick))
            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                self.sources.append(GLib.unix_signal_add(GLib.PRIORITY_HIGH, signum, self.on_signal))
            self.loop.run()
        finally:
            self.cleanup()
        ok, code, message = self.outcome or (False, "vpn_failed", "The VPN could not connect")
        if not ok:
            raise AgentError(code, message)

    def finish(self, ok: bool, code: str = "", message: str = "") -> None:
        if self.outcome is None:
            self.outcome = (ok, code, message)
        self.loop.quit()

    def evaluate(self, state: int, reason: int) -> None:
        if state == STATE_ACTIVATED:
            self.finish(True)
        elif state == STATE_DEACTIVATED:
            self.finish(False, *failure_for_reason(reason, canceled=self.canceled,
                                                   plugin_missing=self.plugin_missing))

    def on_activated(self, bus: Any, result: Any, _data: Any) -> None:
        try:
            self.active_path = bus.call_finish(result).unpack()[0]
        except self.GLib.Error as error:
            self.finish(False, *failure_for_dbus_error(self.remote_error(error)))
            return
        if self.active_path in self.states:
            self.evaluate(*self.states[self.active_path])
        else:
            self.poll_state()

    def on_state(self, _bus: Any, _sender: str, path: str, _interface: str, _signal: str,
                 parameters: Any, _data: Any) -> None:
        state, reason = parameters.unpack()
        self.states[path] = (int(state), int(reason))
        if path == self.active_path:
            self.evaluate(int(state), int(reason))

    def poll_state(self) -> None:
        # Signals are the source of the failure reason; this catches an
        # activation whose signal was missed or whose object already left.
        if not self.active_path or self.outcome is not None:
            return
        try:
            state = self.call(self.active_path, "org.freedesktop.DBus.Properties", "Get", "(ss)",
                              (ACTIVE_INTERFACE, "State"))[0]
        except self.GLib.Error:
            last = self.states.get(self.active_path)
            self.evaluate(STATE_DEACTIVATED, last[1] if last else 0)
            return
        if int(state) == STATE_ACTIVATED:
            self.finish(True)

    # The sources stay installed until cleanup() removes them all at once.
    def on_tick(self) -> bool:
        self.ticks += 1
        if self.dialog is not None and self.dialog.pump():
            self.answer()
        if self.ticks % 5 == 0:
            self.poll_state()
        return True

    def on_deadline(self) -> bool:
        self.finish(False, "vpn_timeout", "The VPN did not finish connecting in time")
        return True

    def on_signal(self) -> bool:
        self.finish(False, "canceled", "Canceled")
        return True

    def on_method(self, _bus: Any, sender: str, _path: str, _interface: str, method: str,
                  parameters: Any, invocation: Any) -> None:
        if method == "GetSecrets":
            self.get_secrets(sender, invocation, *parameters.unpack())
        elif method == "CancelGetSecrets":
            self.cancel_secrets(sender, invocation, *parameters.unpack())
        elif method in ("SaveSecrets", "DeleteSecrets"):
            # Nothing is stored here; the profile's own flags decide storage.
            invocation.return_value(None)
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", "Unknown method")

    def get_secrets(self, sender: str, invocation: Any, connection: dict[str, Any], connection_path: str,
                    setting_name: str, hints: list[str], flags: int) -> None:
        if (sender != self.owner or connection_path != self.connection_path or setting_name != "vpn"
                or self.invocation is not None):
            invocation.return_dbus_error(AGENT_ERROR + ".NoSecrets", "This agent has no such secrets")
            return
        vpn = connection.get("vpn", {})
        identity = connection.get("connection", {})
        service = str(vpn.get("service-type", ""))
        info = plugin_info(service)
        if info is None:
            self.plugin_missing = True
            invocation.return_dbus_error(AGENT_ERROR + ".NoSecrets", "No sign-in dialog for this VPN type")
            return
        argv = dialog_argv(info, str(identity.get("id", "")), str(identity.get("uuid", self.uuid)),
                           service, int(flags), [str(hint) for hint in hints])
        try:
            self.dialog = Dialog(argv, dialog_input(vpn.get("data", {}), vpn.get("secrets", {})))
        except OSError:
            self.plugin_missing = True
            invocation.return_dbus_error(AGENT_ERROR + ".NoSecrets", "The VPN sign-in dialog could not start")
            return
        self.invocation = invocation

    def answer(self) -> None:
        ok, secrets = self.dialog.result() if self.dialog else (False, {})
        invocation, self.invocation, self.dialog = self.invocation, None, None
        if invocation is None:
            return
        if not ok:
            self.canceled = True
            invocation.return_dbus_error(AGENT_ERROR + ".UserCanceled", "The VPN sign-in was canceled")
            return
        GLib = self.GLib
        settings = {"vpn": {"secrets": GLib.Variant("a{ss}", secrets)}} if secrets else {}
        invocation.return_value(GLib.Variant("(a{sa{sv}})", (settings,)))

    def cancel_secrets(self, sender: str, invocation: Any, connection_path: str, _setting_name: str) -> None:
        if sender == self.owner and connection_path == self.connection_path and self.invocation is not None:
            pending, self.invocation = self.invocation, None
            if self.dialog is not None:
                self.dialog.stop()
                self.dialog = None
            pending.return_dbus_error(AGENT_ERROR + ".AgentCanceled", "Canceled")
        invocation.return_value(None)

    def cleanup(self) -> None:
        for source in self.sources:
            self.GLib.source_remove(source)
        self.sources = []
        if self.dialog is not None:
            self.dialog.stop()
            self.dialog = None
        if self.invocation is not None:
            self.invocation.return_dbus_error(AGENT_ERROR + ".AgentCanceled", "Canceled")
            self.invocation = None
        if self.registered:
            try:
                self.call(AGENT_MANAGER_PATH, NM_BUS + ".AgentManager", "Unregister")
            except self.GLib.Error:
                pass
            self.registered = False
        if self.registration:
            self.bus.unregister_object(self.registration)
            self.registration = 0
        if self.subscription:
            self.bus.signal_unsubscribe(self.subscription)
            self.subscription = 0


def activate(uuid: str, deadline: float) -> None:
    """Activate one VPN profile, answering its sign-in; raise AgentError."""
    Activation(uuid, deadline).run()
