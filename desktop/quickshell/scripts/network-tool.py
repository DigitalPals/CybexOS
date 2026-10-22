#!/usr/bin/env python3
"""Bounded NetworkManager helper for the Quickshell Network panel.

Every mutating request is a single JSON object read from stdin.  In
particular, Wi-Fi credentials never cross argv or a temporary file.  The
helper also feeds NetworkManager's passwd-file through stdin and suppresses
child diagnostics for secret-bearing operations so a failed command cannot
echo a credential into the shell journal.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import os
from pathlib import Path
import re
from secrets import choice as secure_choice
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable


PHYSICAL_TYPES = {"802-3-ethernet": "ethernet", "802-11-wireless": "wifi"}
DEVICE_PHYSICAL_TYPES = {"ethernet": "ethernet", "wifi": "wifi"}
PROFILE_FIELDS = (
    "connection.id,connection.uuid,connection.type,connection.interface-name,"
    "connection.master,connection.slave-type,connection.controller,connection.port-type,"
    "ipv4.method,ipv4.dns,ipv4.ignore-auto-dns,"
    "ipv6.method,ipv6.dns,ipv6.ignore-auto-dns,"
    "802-11-wireless.ssid,802-11-wireless.band,802-11-wireless.channel,"
    "802-11-wireless.hidden,802-11-wireless-security.key-mgmt,802-1x.eap"
)
DNS_PROVIDERS = {
    "Cloudflare": (
        "1.1.1.1", "1.0.0.1",
        "2606:4700:4700::1111", "2606:4700:4700::1001",
    ),
    "Google": (
        "8.8.8.8", "8.8.4.4",
        "2001:4860:4860::8888", "2001:4860:4860::8844",
    ),
}
# The connection list every view reads: the snapshot's physical profiles, the
# VPN list and the hotspot all come from this one `nmcli connection show`.
CONNECTION_FIELDS = "NAME,UUID,TYPE,DEVICE,STATE,TIMESTAMP"
VPN_TYPES = ("vpn", "wireguard")
VPN_LABELS = {
    "openvpn": "OpenVPN",
    "openconnect": "OpenConnect",
    "vpnc": "Cisco IPsec",
    "ssh": "SSH",
    "l2tp": "L2TP",
    "pptp": "PPTP",
    "strongswan": "IPsec",
    "libreswan": "IPsec",
    "fortisslvpn": "Fortinet SSL",
    "sstp": "SSTP",
    "wireguard": "WireGuard",
}
# The hotspot is one managed NetworkManager profile with a fixed identity, so
# every surface finds the same profile and never touches a user's own AP
# profiles. The name is the fallback match if NetworkManager ever assigns a
# different UUID.
HOTSPOT_UUID = "6f1c2d9a-3b7e-4c5a-9e21-c7b0f4a8d153"
HOTSPOT_NAME = "CybexOS hotspot"
# Shared mode runs NetworkManager's DHCP and DNS for the clients; the
# nm-shared firewalld zone admits exactly those and forwards their traffic.
# The CybexOS zone drops them, so the hotspot never joins it. WPA2-only
# (CCMP) with PMF off works with the widest range of clients and access-point
# drivers; 2.4 GHz avoids the no-IR limits many adapters have on 5 GHz.
HOTSPOT_SETTINGS = (
    "connection.uuid", HOTSPOT_UUID,
    "connection.autoconnect", "no",
    "connection.zone", "nm-shared",
    "802-11-wireless.mode", "ap",
    "802-11-wireless.band", "bg",
    "ipv4.method", "shared",
    "ipv6.method", "ignore",
    "802-11-wireless-security.key-mgmt", "wpa-psk",
    "802-11-wireless-security.proto", "rsn",
    "802-11-wireless-security.pairwise", "ccmp",
    "802-11-wireless-security.group", "ccmp",
    "802-11-wireless-security.pmf", "disable",
)
# Readable aloud and typed on a phone: no 0/o, 1/l/i. Sixteen characters from
# 31 is about 79 bits, well beyond an offline WPA2 dictionary attack.
PASSWORD_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
MAX_IMPORT_BYTES = 1024 * 1024
OPENVPN_DIRECTIVES = {"client", "remote", "dev", "proto", "auth-user-pass", "tls-client", "<ca>", "ca"}
KERNEL_IFNAME_RE = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
IFACE_RE = re.compile(r"^[A-Za-z0-9_.:@+-]{1,64}$")


class ToolError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def timeout(name: str, fallback: float) -> float:
    try:
        value = float(os.environ.get(name, fallback))
    except ValueError:
        return fallback
    return min(60.0, max(0.1, value))


def safe_detail(stderr: str, fallback: str) -> str:
    first = next((line.strip() for line in stderr.splitlines() if line.strip()), "")
    if not first:
        return fallback
    # nmcli's diagnostics normally name only a profile or device.  Bound and
    # flatten them before returning to QML; secret-bearing callers never use
    # this function at all.
    return first[:240].replace("\x00", "")


def run(
    argv: list[str],
    *,
    input_text: str | None = None,
    seconds: float | None = None,
    code: str = "command_failed",
    label: str | None = None,
    secret: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    limit = seconds if seconds is not None else timeout("NETWORK_TOOL_TIMEOUT", 6.0)
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            argv,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=limit,
            check=False,
        )
    except FileNotFoundError as error:
        raise ToolError("missing_dependency", f"{argv[0]} is not installed") from error
    except subprocess.TimeoutExpired as error:
        raise ToolError("timeout", f"{label or argv[0]} timed out") from error
    if check and result.returncode != 0:
        fallback = f"{label or argv[0]} failed"
        message = fallback if secret else safe_detail(result.stderr, fallback)
        raise ToolError(code, message)
    return result


def read_request() -> dict[str, Any]:
    line = sys.stdin.readline(65537)
    if not line:
        raise ToolError("invalid_request", "A JSON request is required on stdin")
    if len(line) > 65536:
        raise ToolError("invalid_request", "The request is too large")
    try:
        request = json.loads(line)
    except json.JSONDecodeError as error:
        raise ToolError("invalid_request", "The stdin request is not valid JSON") from error
    if not isinstance(request, dict):
        raise ToolError("invalid_request", "The request must be a JSON object")
    return request


def emit(payload: dict[str, Any], status: int = 0) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    raise SystemExit(status)


def unescape_nmcli(value: str) -> str:
    output: list[str] = []
    escaped = False
    for char in value:
        if escaped:
            output.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        else:
            output.append(char)
    if escaped:
        raise ToolError("invalid_nmcli", "NetworkManager returned a dangling escape")
    return "".join(output)


def split_escaped(value: str, separator: str = ":") -> list[str]:
    output: list[str] = []
    current: list[str] = []
    escaped = False
    for char in value:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == separator:
            output.append("".join(current))
            current = []
        else:
            current.append(char)
    if escaped:
        raise ToolError("invalid_nmcli", "NetworkManager returned a dangling escape")
    output.append("".join(current))
    return output


def field_line(line: str) -> tuple[str, str]:
    parts = split_escaped(line)
    if len(parts) < 2 or not parts[0]:
        raise ToolError("invalid_nmcli", "NetworkManager returned malformed status")
    return parts[0], ":".join(parts[1:])


def multiline_records(output: str, start_key: str) -> list[dict[str, list[str]]]:
    records: list[dict[str, list[str]]] = []
    current: dict[str, list[str]] | None = None
    for raw_line in output.replace("\r\n", "\n").split("\n"):
        if raw_line == "":
            if current is not None:
                records.append(current)
                current = None
            continue
        key, value = field_line(raw_line)
        if key == start_key:
            if current is not None:
                records.append(current)
            current = {}
        if current is None:
            raise ToolError("invalid_nmcli", "NetworkManager returned fields out of order")
        current.setdefault(key, []).append(value)
    if current is not None:
        records.append(current)
    return records


def first(record: dict[str, list[str]], key: str, fallback: str = "") -> str:
    values = record.get(key, [])
    return values[0] if values else fallback


def parse_state(value: str) -> int:
    match = re.match(r"^(\d+)", value)
    return int(match.group(1)) if match else 0


def parse_devices(output: str) -> list[dict[str, Any]]:
    devices: list[dict[str, Any]] = []
    for record in multiline_records(output, "GENERAL.DEVICE"):
        interface = first(record, "GENERAL.DEVICE")
        kind = DEVICE_PHYSICAL_TYPES.get(first(record, "GENERAL.TYPE"), first(record, "GENERAL.TYPE"))
        state = parse_state(first(record, "GENERAL.STATE"))
        addresses = [value.split("/", 1)[0] for key, values in record.items()
                     if key.startswith("IP4.ADDRESS") for value in values if value]
        devices.append({
            "interface": interface,
            "type": kind,
            "nmType": first(record, "GENERAL.NM-TYPE"),
            "connection": "" if first(record, "GENERAL.CONNECTION") == "--"
            else first(record, "GENERAL.CONNECTION"),
            "uuid": first(record, "GENERAL.CON-UUID"),
            "stateCode": state,
            "state": "connected" if state == 100 else "disconnected" if state <= 30 else "connecting",
            "connected": state == 100,
            "managed": state not in (10,),
            "ipv4": addresses[0] if addresses else "",
            "gateway": first(record, "IP4.GATEWAY"),
        })
    return devices


def parse_profile_summary(output: str) -> list[dict[str, Any]]:
    profiles: list[dict[str, Any]] = []
    for record in multiline_records(output, "NAME"):
        connection_type = first(record, "TYPE")
        profiles.append({
            "name": first(record, "NAME"),
            "uuid": first(record, "UUID"),
            "connectionType": connection_type,
            "type": PHYSICAL_TYPES.get(connection_type, connection_type),
            "device": "" if first(record, "DEVICE") == "--" else first(record, "DEVICE"),
            "active": first(record, "DEVICE") not in ("", "--"),
        })
    return profiles


def connection_state(record: dict[str, list[str]]) -> str:
    state = first(record, "STATE").strip().lower()
    if state in ("", "--", "deactivated"):
        # Without a STATE column a bound device still means it is up.
        return "activated" if not state and first(record, "DEVICE") not in ("", "--") else ""
    return state


def parse_vpn_profiles(output: str) -> list[dict[str, Any]]:
    """NetworkManager VPN-plugin and WireGuard profiles, sorted by name.

    `kind` and `label` say what the profile is as far as the list knows;
    add_vpn_kinds() names the plugin of a `vpn` profile when asked to.
    """
    vpns: list[dict[str, Any]] = []
    for record in multiline_records(output, "NAME"):
        connection_type = first(record, "TYPE")
        if connection_type not in VPN_TYPES or not UUID_RE.fullmatch(first(record, "UUID")):
            continue
        try:
            stamp = max(0, int(first(record, "TIMESTAMP", "0") or 0))
        except ValueError:
            stamp = 0
        state = connection_state(record)
        wireguard = connection_type == "wireguard"
        vpns.append({
            "name": first(record, "NAME"),
            "uuid": first(record, "UUID"),
            "type": connection_type,
            "kind": "wireguard" if wireguard else "",
            "label": "WireGuard" if wireguard else "VPN",
            "state": state,
            "active": state == "activated",
            "device": "" if first(record, "DEVICE") == "--" else first(record, "DEVICE"),
            "timestamp": stamp,
        })
    vpns.sort(key=lambda vpn: (vpn["name"].casefold(), vpn["uuid"]))
    return vpns


def parse_frequency(value: str) -> int | None:
    match = re.search(r"\d+(?:\.\d+)?", value)
    return round(float(match.group(0))) if match else None


def parse_wifi_list(output: str, profiles: list[dict[str, Any]], active_uuid: str) -> list[dict[str, Any]]:
    by_name = {profile["name"]: profile for profile in profiles
               if profile.get("type") == "wifi"}
    networks: list[dict[str, Any]] = []
    for line in output.replace("\r\n", "\n").splitlines():
        if not line:
            continue
        values = split_escaped(line)
        if len(values) != 6:
            raise ToolError("invalid_nmcli", "NetworkManager returned a malformed Wi-Fi scan")
        in_use, ssid, bssid, signal_value, frequency_value, security = values
        if not ssid:
            continue
        profile = by_name.get(ssid, {})
        try:
            strength = max(0, min(100, int(signal_value)))
        except ValueError:
            strength = -1
        networks.append({
            "ssid": ssid,
            "bssid": bssid.lower(),
            "signal": strength,
            "frequency": parse_frequency(frequency_value),
            "security": security,
            "connected": in_use.strip() == "*",
            "known": bool(profile),
            "profileUuid": active_uuid if in_use.strip() == "*" and active_uuid else profile.get("uuid", ""),
            "profileName": profile.get("name", ""),
        })
    return networks


def parse_routes(output: str) -> list[dict[str, Any]]:
    try:
        raw_routes = json.loads(output or "[]")
    except json.JSONDecodeError as error:
        raise ToolError("invalid_ip", "ip returned malformed route data") from error
    if not isinstance(raw_routes, list):
        raise ToolError("invalid_ip", "ip returned malformed route data")
    routes: list[dict[str, Any]] = []
    for route in raw_routes:
        if not isinstance(route, dict):
            continue
        destination = str(route.get("dst", "default"))
        if destination not in ("default", "0.0.0.0/0", "::/0", ""):
            continue
        metric_value = route.get("metric", 2**31 - 1)
        try:
            metric_number = int(metric_value)
        except (TypeError, ValueError):
            metric_number = 2**31 - 1
        routes.append({
            "destination": destination or "default",
            "interface": str(route.get("dev", "")),
            "gateway": str(route.get("gateway", "")),
            "metric": metric_number,
            "source": str(route.get("prefsrc", "")),
        })
    return routes


def counter_root() -> Path:
    return Path(os.environ.get("NETWORK_TOOL_SYS_CLASS_NET", "/sys/class/net"))


def read_counter(interface: str, counter: str) -> int | None:
    if not IFACE_RE.fullmatch(interface):
        return None
    try:
        value = (counter_root() / interface / "statistics" / counter).read_text().strip()
        number = int(value)
        return number if number >= 0 else None
    except (OSError, ValueError):
        return None


def read_link_attribute(interface: str, attribute: str) -> str:
    if not IFACE_RE.fullmatch(interface):
        return ""
    try:
        return (counter_root() / interface / attribute).read_text().strip()
    except OSError:
        return ""


def link_info(interface: str) -> dict[str, Any]:
    if not interface:
        return {}
    result = run(["iw", "dev", interface, "link"], seconds=timeout("NETWORK_TOOL_IW_TIMEOUT", 3),
                 label="Wi-Fi link lookup", check=False)
    if result.returncode != 0:
        return {}
    output: dict[str, Any] = {}
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("SSID:"):
            output["ssid"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("freq:"):
            output["frequency"] = parse_frequency(stripped.split(":", 1)[1])
        elif stripped.startswith("signal:"):
            match = re.search(r"-?\d+(?:\.\d+)?", stripped)
            if match:
                output["signalDbm"] = float(match.group(0))
        elif stripped.startswith("rx bitrate:"):
            match = re.search(r"\d+(?:\.\d+)?", stripped)
            if match:
                output["rxBitrateMbps"] = float(match.group(0))
        elif stripped.startswith("tx bitrate:"):
            match = re.search(r"\d+(?:\.\d+)?", stripped)
            if match:
                output["txBitrateMbps"] = float(match.group(0))
    return output


def wifi_scan(interface: str) -> subprocess.CompletedProcess[str]:
    return run([
        "nmcli", "-t", "--escape", "yes", "-f",
        "IN-USE,SSID,BSSID,SIGNAL,FREQ,SECURITY", "device", "wifi", "list",
        "ifname", interface, "--rescan", "no",
    ], seconds=timeout("NETWORK_TOOL_SCAN_TIMEOUT", 5), label="Wi-Fi scan", check=False)


def snapshot() -> dict[str, Any]:
    # The panel asks for this on NetworkManager events and a slow safety
    # poll, so independent lookups run side by side: the three
    # NetworkManager/ip reads first, then the Wi-Fi scan and link, which only
    # need the first round's answers.  Results are collected in the old
    # sequential order, so the first failure reported is unchanged.  Latency
    # and live throughput are not measured here: NetworkDetails keeps
    # long-lived pings and reads the byte counters itself.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        return snapshot_with(executor)


def snapshot_with(executor: concurrent.futures.Executor) -> dict[str, Any]:
    devices_future = executor.submit(run, [
        "nmcli", "-t", "--escape", "yes", "-m", "multiline", "-f",
        "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.NM-TYPE,GENERAL.CONNECTION,"
        "GENERAL.CON-UUID,GENERAL.STATE,IP4.ADDRESS,IP4.GATEWAY",
        "device", "show",
    ], label="NetworkManager device status")
    route_future = executor.submit(run, ["ip", "-j", "route", "show", "default"],
                                   seconds=timeout("NETWORK_TOOL_IP_TIMEOUT", 4),
                                   label="default route lookup")
    profiles_future = executor.submit(run, connection_list_command(),
                                      label="NetworkManager profile status")
    devices_result = devices_future.result()
    route_result = route_future.result()
    profiles_result = profiles_future.result()

    devices = parse_devices(devices_result.stdout)
    routes = parse_routes(route_result.stdout)
    profiles = parse_profile_summary(profiles_result.stdout)
    for device in devices:
        device["rxBytes"] = read_counter(device["interface"], "rx_bytes")
        device["txBytes"] = read_counter(device["interface"], "tx_bytes")
        if device["type"] == "ethernet":
            speed = read_link_attribute(device["interface"], "speed")
            duplex = read_link_attribute(device["interface"], "duplex").lower()
            if speed.isdigit() and int(speed) > 0:
                device["speedMbps"] = int(speed)
                device["speed"] = f"{speed} Mbps"
            if duplex in ("full", "half"):
                device["duplex"] = duplex
        matching_route = next((route for route in sorted(routes, key=lambda item: item["metric"])
                               if route["interface"] == device["interface"]), None)
        if matching_route:
            device["defaultMetric"] = matching_route["metric"]
            device["gateway"] = device.get("gateway") or matching_route.get("gateway", "")

    wifi_device = next((device for device in devices if device["type"] == "wifi"), None)
    scan_future = executor.submit(wifi_scan, wifi_device["interface"]) if wifi_device else None
    link_future = executor.submit(link_info, wifi_device["interface"]) if wifi_device else None

    networks: list[dict[str, Any]] = []
    link: dict[str, Any] = {}
    if wifi_device and scan_future and link_future:
        scan_result = scan_future.result()
        if scan_result.returncode == 0:
            networks = parse_wifi_list(scan_result.stdout, profiles, wifi_device.get("uuid", ""))
        link = link_future.result()
        if link.get("ssid"):
            wifi_device["ssid"] = link["ssid"]
        connected_ap = next((network for network in networks if network["connected"]), None)
        if connected_ap:
            wifi_device["ssid"] = connected_ap["ssid"]
            wifi_device["signal"] = connected_ap["signal"]
            wifi_device["frequency"] = connected_ap["frequency"]
            wifi_device["security"] = connected_ap["security"]
        wifi_device.update({key: value for key, value in link.items() if key != "ssid"})

    return {
        "success": True,
        "timestamp": int(time.time() * 1000),
        "devices": devices,
        "routes": routes,
        "profiles": profiles,
        # The drawer's VPN switch reads these; they come from the same list.
        "vpns": parse_vpn_profiles(profiles_result.stdout),
        "wifi": {
            "interface": wifi_device["interface"] if wifi_device else "",
            "networks": networks,
            "link": link,
        },
    }


def detail_record(output: str) -> dict[str, str]:
    record: dict[str, str] = {}
    for line in output.replace("\r\n", "\n").splitlines():
        if not line:
            continue
        key, value = field_line(line)
        record[key] = value
    return record


def split_dns(value: str) -> list[str]:
    return [item for item in re.split(r"[\s,;]+", value.strip()) if item]


def selected_band(record: dict[str, str]) -> str:
    band = record.get("802-11-wireless.band", "").lower()
    try:
        channel = int(record.get("802-11-wireless.channel", "0") or 0)
    except ValueError:
        channel = 0
    if band == "bg":
        return "2.4"
    if band == "a":
        # NetworkManager exposes only a/bg.  The helper represents a 6 GHz
        # pin as band=a plus a 6 GHz-only channel (>180); see band_action.
        return "6" if channel > 180 else "5"
    return "auto"


def get_profile_detail(summary: dict[str, Any]) -> dict[str, Any]:
    profile_uuid = require_uuid(summary.get("uuid"))
    result = run([
        "nmcli", "-t", "--escape", "yes", "-f", PROFILE_FIELDS,
        "connection", "show", "uuid", profile_uuid,
    ], label=f"profile {summary.get('name') or profile_uuid}")
    record = detail_record(result.stdout)
    connection_type = record.get("connection.type", summary.get("connectionType", ""))
    eap = split_dns(record.get("802-1x.eap", ""))
    profile = {
        "name": record.get("connection.id", summary.get("name", "")),
        "uuid": record.get("connection.uuid", profile_uuid),
        "connectionType": connection_type,
        "type": PHYSICAL_TYPES.get(connection_type, connection_type),
        "interface": record.get("connection.interface-name", ""),
        "device": summary.get("device", ""),
        "active": bool(summary.get("active")),
        "master": record.get("connection.master", ""),
        "slaveType": record.get("connection.slave-type", ""),
        "controller": record.get("connection.controller", ""),
        "portType": record.get("connection.port-type", ""),
        "ipv4Method": record.get("ipv4.method", ""),
        "ipv4Dns": split_dns(record.get("ipv4.dns", "")),
        "ipv4IgnoreAutoDns": record.get("ipv4.ignore-auto-dns", "no") == "yes",
        "ipv6Method": record.get("ipv6.method", ""),
        "ipv6Dns": split_dns(record.get("ipv6.dns", "")),
        "ipv6IgnoreAutoDns": record.get("ipv6.ignore-auto-dns", "no") == "yes",
        "ssid": record.get("802-11-wireless.ssid", ""),
        "band": record.get("802-11-wireless.band", ""),
        "channel": int(record.get("802-11-wireless.channel", "0") or 0),
        "selectedBand": selected_band(record),
        "hidden": record.get("802-11-wireless.hidden", "no") == "yes",
        "security": record.get("802-11-wireless-security.key-mgmt", ""),
        "eap": eap,
        "certificateEnterprise": any(method.lower() == "tls" for method in eap),
    }
    profile["standalone"] = not any((profile["master"], profile["slaveType"],
                                      profile["controller"], profile["portType"]))
    return profile


def connection_list_command() -> list[str]:
    return ["nmcli", "-t", "--escape", "yes", "-m", "multiline", "-f",
            CONNECTION_FIELDS, "connection", "show"]


def profile_summaries() -> list[dict[str, Any]]:
    result = run(connection_list_command(), label="NetworkManager profile status")
    return parse_profile_summary(result.stdout)


def physical_profiles() -> list[dict[str, Any]]:
    summaries = [profile for profile in profile_summaries()
                 if profile.get("connectionType") in PHYSICAL_TYPES]
    if len(summaries) > 128:
        raise ToolError("too_many_profiles", "Too many physical network profiles to update safely")
    return [get_profile_detail(profile) for profile in summaries]


def bool_value(value: Any) -> bool:
    return value is True or str(value).lower() in ("yes", "true", "1")


def target_profile(profile: dict[str, Any]) -> bool:
    # A shared (hotspot) profile serves DNS to its clients itself; the
    # upstream provider choice is not its setting.
    return (profile.get("connectionType") in PHYSICAL_TYPES and bool(profile.get("standalone", True))
            and profile.get("ipv4Method") != "shared")


def normalized_servers(values: Iterable[str]) -> list[str]:
    output: list[str] = []
    for value in values:
        try:
            canonical = str(ipaddress.ip_address(value))
        except ValueError:
            canonical = value.lower()
        if canonical not in output:
            output.append(canonical)
    return output


def profile_dns_state(profile: dict[str, Any]) -> dict[str, Any]:
    servers = normalized_servers((*profile.get("ipv4Dns", []), *profile.get("ipv6Dns", [])))
    ignore4 = bool_value(profile.get("ipv4IgnoreAutoDns"))
    ignore6 = bool_value(profile.get("ipv6IgnoreAutoDns"))
    if not servers and not ignore4 and not ignore6:
        return {"provider": "Automatic", "servers": []}
    for name, provider_servers in DNS_PROVIDERS.items():
        if ignore4 and ignore6 and set(servers) == set(provider_servers):
            return {"provider": name, "servers": list(provider_servers)}
    return {"provider": "Custom", "servers": servers}


def aggregate_dns_state(profiles: list[dict[str, Any]]) -> dict[str, Any]:
    targets = [profile for profile in profiles if target_profile(profile)]
    if not targets:
        return {"provider": "Automatic", "servers": [], "mixed": False}
    states = [profile_dns_state(profile) for profile in targets]
    signatures = {(state["provider"], tuple(sorted(state["servers"]))) for state in states}
    if len(signatures) != 1:
        return {"provider": "Mixed", "servers": [], "mixed": True}
    return {**states[0], "mixed": False}


def validate_dns_servers(value: Any) -> list[str]:
    if isinstance(value, str):
        raw = [item for item in re.split(r"[\s,;]+", value) if item]
    elif isinstance(value, list):
        raw = value
    else:
        raise ToolError("invalid_dns", "Custom DNS servers must be a string or list")
    servers: list[str] = []
    for item in raw:
        if not isinstance(item, str):
            raise ToolError("invalid_dns", "Every DNS server must be a literal IP address")
        try:
            server = str(ipaddress.ip_address(item.strip()))
        except ValueError as error:
            raise ToolError("invalid_dns", f"{item.strip()} is not a literal IP address") from error
        if server not in servers:
            servers.append(server)
        if len(servers) > 4:
            raise ToolError("invalid_dns", "Enter at most four DNS servers")
    if not servers:
        raise ToolError("invalid_dns", "Enter at least one DNS server")
    return servers


def provider_configuration(provider: str, custom: Any = None) -> dict[str, Any]:
    normalized = next((name for name in ("Automatic", "Cloudflare", "Google", "Custom")
                       if name.lower() == provider.lower()), None)
    if normalized is None:
        raise ToolError("invalid_dns", "Unknown DNS provider")
    servers = validate_dns_servers(custom) if normalized == "Custom" \
        else list(DNS_PROVIDERS.get(normalized, ()))
    ipv4 = [server for server in servers if ipaddress.ip_address(server).version == 4]
    ipv6 = [server for server in servers if ipaddress.ip_address(server).version == 6]
    automatic = normalized == "Automatic"
    return {
        "provider": normalized,
        "servers": servers,
        "ipv4Dns": ipv4,
        "ipv6Dns": ipv6,
        "ipv4IgnoreAutoDns": not automatic,
        "ipv6IgnoreAutoDns": not automatic,
    }


def dns_settings(profile: dict[str, Any]) -> dict[str, Any]:
    return {
        "ipv4Dns": list(profile.get("ipv4Dns", [])),
        "ipv6Dns": list(profile.get("ipv6Dns", [])),
        "ipv4IgnoreAutoDns": bool_value(profile.get("ipv4IgnoreAutoDns")),
        "ipv6IgnoreAutoDns": bool_value(profile.get("ipv6IgnoreAutoDns")),
    }


def modify_dns(profile_uuid: str, settings: dict[str, Any], *, rollback: bool = False) -> None:
    run([
        "nmcli", "connection", "modify", "uuid", require_uuid(profile_uuid),
        "ipv4.dns", ",".join(settings.get("ipv4Dns", [])),
        "ipv4.ignore-auto-dns", "yes" if settings.get("ipv4IgnoreAutoDns") else "no",
        "ipv6.dns", ",".join(settings.get("ipv6Dns", [])),
        "ipv6.ignore-auto-dns", "yes" if settings.get("ipv6IgnoreAutoDns") else "no",
    ], code="dns_rollback_failed" if rollback else "dns_modify_failed",
        label="DNS rollback" if rollback else "DNS profile update")


def dns_status_payload(profiles: list[dict[str, Any]]) -> dict[str, Any]:
    state = aggregate_dns_state(profiles)
    return {"success": True, **state, "profiles": profiles}


def dns_action(request: dict[str, Any]) -> dict[str, Any]:
    profiles = physical_profiles()
    provider = str(request.get("provider", request.get("action", "status")))
    if provider.lower() in ("", "status", "get"):
        return dns_status_payload(profiles)
    configuration = provider_configuration(provider, request.get("servers"))
    targets = [profile for profile in profiles if target_profile(profile)]
    snapshots = {profile["uuid"]: dns_settings(profile) for profile in targets}
    attempted: list[dict[str, Any]] = []
    try:
        for profile in targets:
            attempted.append(profile)
            modify_dns(profile["uuid"], configuration)
    except ToolError as original:
        rollback_failures: list[str] = []
        # Include the profile whose modify command failed: nmcli normally
        # commits atomically, but restoring its exact snapshot makes the
        # transaction safe even if a future backend reports a partial write.
        for profile in reversed(attempted):
            try:
                modify_dns(profile["uuid"], snapshots[profile["uuid"]], rollback=True)
            except ToolError:
                rollback_failures.append(profile["name"])
        if rollback_failures:
            raise ToolError("dns_rollback_failed",
                            "DNS update failed and rollback also failed for " + ", ".join(rollback_failures))
        raise original

    reconnect_devices: list[str] = []
    reapplied: list[str] = []
    for device in dict.fromkeys(profile.get("device", "") for profile in targets if profile.get("active")):
        if not device or not IFACE_RE.fullmatch(device):
            continue
        result = run(["nmcli", "device", "reapply", device], label="DNS reapply", check=False)
        if result.returncode == 0:
            reapplied.append(device)
        else:
            reconnect_devices.append(device)
    return {
        "success": True,
        "provider": configuration["provider"],
        "servers": configuration["servers"],
        "mixed": False,
        "profiles": len(targets),
        "reapplied": reapplied,
        "reconnectRequired": bool(reconnect_devices),
        "reconnectDevices": reconnect_devices,
    }


def require_uuid(value: Any) -> str:
    candidate = str(value or "")
    if not UUID_RE.fullmatch(candidate):
        raise ToolError("invalid_request", "A valid connection UUID is required")
    return candidate


def require_interface(value: Any) -> str:
    candidate = str(value or "")
    if not IFACE_RE.fullmatch(candidate):
        raise ToolError("invalid_request", "A valid network interface is required")
    return candidate


def require_ssid(value: Any) -> str:
    candidate = str(value or "")
    if not candidate or "\x00" in candidate or "\n" in candidate or "\r" in candidate:
        raise ToolError("invalid_request", "A Wi-Fi network name is required")
    if len(candidate.encode("utf-8")) > 32:
        raise ToolError("invalid_request", "The Wi-Fi network name is longer than 32 bytes")
    return candidate


def credential(value: Any, label: str, required: bool = False) -> str:
    candidate = "" if value is None else str(value)
    if "\x00" in candidate or "\n" in candidate or "\r" in candidate or len(candidate) > 4096:
        raise ToolError("invalid_credentials", f"The {label} contains unsupported characters")
    if required and not candidate:
        raise ToolError("invalid_credentials", f"Enter the {label}")
    return candidate


def security_kind(value: Any) -> str:
    raw = str(value or "").upper()
    if raw in ("", "--", "NONE", "OPEN"):
        return "open"
    if "OWE" in raw:
        return "owe"
    if "WEP" in raw:
        return "wep"
    if any(token in raw for token in ("EAP", "802.1X", "ENTERPRISE", "LEAP")):
        return "enterprise"
    if "SAE" in raw or "WPA3" in raw:
        return "wpa3"
    if "WPA" in raw or "PSK" in raw:
        return "wpa"
    return "unsupported"


def passwd_file(kind: str, request: dict[str, Any]) -> str:
    if kind in ("open", "owe"):
        return ""
    if kind == "wep":
        password = credential(request.get("password"), "WEP key", required=True)
        return f"802-11-wireless-security.wep-key0:{password}\n"
    if kind in ("wpa", "wpa3"):
        password = credential(request.get("password"), "password", required=True)
        return f"802-11-wireless-security.psk:{password}\n"
    if kind == "enterprise":
        identity = credential(request.get("identity"), "identity", required=True)
        password = credential(request.get("password"), "password", required=True)
        return f"802-1x.identity:{identity}\n802-1x.password:{password}\n"
    raise ToolError("unsupported_security", "Use Network Settings for this network's security method")


def activate(profile_uuid: str, interface: str, secrets: str) -> None:
    run([
        "nmcli", "--wait", "25", "connection", "up", "uuid", require_uuid(profile_uuid),
        "ifname", require_interface(interface), "passwd-file", "/dev/stdin",
    ], input_text=secrets, seconds=timeout("NETWORK_TOOL_ACTIVATE_TIMEOUT", 30),
        code="activation_failed", label="Wi-Fi activation", secret=True)


def parse_added_uuid(output: str) -> str:
    matches = re.findall(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", output)
    return matches[-1] if matches else ""


def inherit_dns_for_new_profile(profile_uuid: str, previous_profiles: list[dict[str, Any]]) -> None:
    state = aggregate_dns_state(previous_profiles)
    if state["mixed"]:
        return
    configuration = provider_configuration(state["provider"], state["servers"])
    modify_dns(profile_uuid, configuration)


def wifi_action(request: dict[str, Any]) -> dict[str, Any]:
    action = str(request.get("action", ""))
    if action == "disconnect":
        interface = require_interface(request.get("interface"))
        run(["nmcli", "--wait", "15", "device", "disconnect", interface],
            seconds=timeout("NETWORK_TOOL_ACTION_TIMEOUT", 20), label="Wi-Fi disconnect")
        return {"success": True, "action": action, "interface": interface}
    if action == "forget":
        profile_uuid = require_uuid(request.get("uuid"))
        run(["nmcli", "connection", "delete", "uuid", profile_uuid], label="Forget Wi-Fi network")
        return {"success": True, "action": action, "uuid": profile_uuid}
    if action != "connect":
        raise ToolError("invalid_request", "Unknown Wi-Fi action")

    interface = require_interface(request.get("interface"))
    profile_uuid = str(request.get("uuid", ""))
    kind = security_kind(request.get("security"))
    # A known profile normally obtains its saved secret from NetworkManager.
    # passwd-file is still used for activation, but an empty file lets NM use
    # the keyring/profile instead of making the UI reveal and retransmit it.
    saved_without_new_secret = bool(profile_uuid and request.get("saved")
                                    and request.get("password") in (None, "")
                                    and request.get("identity") in (None, ""))
    secrets = "" if saved_without_new_secret else passwd_file(kind, request)
    created = False
    if profile_uuid:
        profile_uuid = require_uuid(profile_uuid)
    else:
        ssid = require_ssid(request.get("ssid"))
        previous_profiles = physical_profiles()
        result = run([
            "nmcli", "connection", "add", "type", "wifi", "ifname", interface,
            "con-name", ssid, "ssid", ssid,
        ], label="Create Wi-Fi profile")
        profile_uuid = parse_added_uuid(result.stdout)
        if not profile_uuid:
            # Compare summaries instead of deleting by connection name: a
            # same-named existing profile must never become cleanup collateral.
            previous_uuids = {profile["uuid"] for profile in previous_profiles}
            fresh = [profile for profile in profile_summaries()
                     if profile.get("connectionType") == "802-11-wireless"
                     and profile.get("uuid") not in previous_uuids]
            if len(fresh) == 1:
                profile_uuid = fresh[0]["uuid"]
        if not UUID_RE.fullmatch(profile_uuid):
            raise ToolError("profile_create_failed", "NetworkManager did not identify the new profile")
        created = True
        try:
            modifications: list[str] = []
            if bool(request.get("hidden")):
                modifications += ["802-11-wireless.hidden", "yes"]
            if kind == "owe":
                modifications += ["802-11-wireless-security.key-mgmt", "owe"]
            elif kind == "wep":
                modifications += ["802-11-wireless-security.key-mgmt", "none",
                                  "802-11-wireless-security.wep-key-type", "key"]
            elif kind == "wpa":
                modifications += ["802-11-wireless-security.key-mgmt", "wpa-psk"]
            elif kind == "wpa3":
                modifications += ["802-11-wireless-security.key-mgmt", "sae"]
            elif kind == "enterprise":
                modifications += [
                    "802-11-wireless-security.key-mgmt", "wpa-eap",
                    "802-1x.eap", "peap", "802-1x.phase2-auth", "mschapv2",
                ]
            elif kind != "open":
                raise ToolError("unsupported_security", "Use Network Settings for this network's security method")
            if modifications:
                run(["nmcli", "connection", "modify", "uuid", profile_uuid, *modifications],
                    label="Configure Wi-Fi profile")
            inherit_dns_for_new_profile(profile_uuid, previous_profiles)
        except ToolError:
            run(["nmcli", "connection", "delete", "uuid", profile_uuid], check=False,
                label="Remove incomplete Wi-Fi profile")
            raise
    try:
        activate(profile_uuid, interface, secrets)
    except ToolError:
        if created:
            run(["nmcli", "connection", "delete", "uuid", profile_uuid], check=False,
                label="Remove failed Wi-Fi profile")
        raise
    return {"success": True, "action": action, "uuid": profile_uuid, "created": created}


def frequency_to_6ghz_channel(frequency: Any) -> int:
    try:
        value = int(round(float(frequency)))
    except (TypeError, ValueError) as error:
        raise ToolError("invalid_band", "A scanned 6 GHz frequency is required") from error
    if value == 5935:
        return 2
    channel = round((value - 5950) / 5)
    if value < 5955 or value > 7115 or channel < 1 or channel > 233:
        raise ToolError("invalid_band", "The selected access point is not in the 6 GHz band")
    return channel


def modify_band(profile_uuid: str, band: str, channel: int, *, rollback: bool = False) -> None:
    run([
        "nmcli", "connection", "modify", "uuid", require_uuid(profile_uuid),
        "802-11-wireless.band", band,
        "802-11-wireless.channel", str(channel),
    ], code="band_rollback_failed" if rollback else "band_modify_failed",
        label="Band rollback" if rollback else "Band profile update")


def band_action(request: dict[str, Any]) -> dict[str, Any]:
    profile_uuid = require_uuid(request.get("uuid"))
    summary = next((profile for profile in profile_summaries() if profile["uuid"] == profile_uuid), None)
    if not summary or summary.get("connectionType") != "802-11-wireless":
        raise ToolError("invalid_band", "The active Wi-Fi profile no longer exists")
    profile = get_profile_detail(summary)
    if (profile.get("band") == "a" and profile.get("channel", 0)
            and (profile.get("device") or profile.get("interface"))):
        active_link = link_info(profile.get("device") or profile.get("interface"))
        frequency = active_link.get("frequency")
        if frequency is not None and frequency >= 5925:
            profile["selectedBand"] = "6"
    selected = str(request.get("band", "status"))
    if selected in ("", "status", "get"):
        return {"success": True, "selected": profile["selectedBand"],
                "band": profile["band"], "channel": profile["channel"], "profile": profile}
    if selected not in ("auto", "2.4", "5", "6"):
        raise ToolError("invalid_band", "Choose Automatic, 2.4, 5, or 6 GHz")
    interface = require_interface(request.get("interface") or profile.get("device") or profile.get("interface"))
    old_band = profile["band"]
    old_channel = profile["channel"]
    new_band = "" if selected == "auto" else "bg" if selected == "2.4" else "a"
    new_channel = frequency_to_6ghz_channel(request.get("frequency")) if selected == "6" else 0
    modify_band(profile_uuid, new_band, new_channel)
    try:
        run(["nmcli", "--wait", "25", "connection", "up", "uuid", profile_uuid,
             "ifname", interface], seconds=timeout("NETWORK_TOOL_ACTIVATE_TIMEOUT", 30),
            code="band_activation_failed", label="Band reconnect")
    except ToolError as original:
        try:
            modify_band(profile_uuid, old_band, old_channel, rollback=True)
            run(["nmcli", "--wait", "25", "connection", "up", "uuid", profile_uuid,
                 "ifname", interface], seconds=timeout("NETWORK_TOOL_ACTIVATE_TIMEOUT", 30),
                code="band_rollback_failed", label="Band rollback reconnect")
        except ToolError as rollback_error:
            raise ToolError("band_rollback_failed",
                            "Band reconnect failed and the previous profile could not be restored") from rollback_error
        raise original
    return {"success": True, "selected": selected, "uuid": profile_uuid}


def password_action(request: dict[str, Any]) -> dict[str, Any]:
    profile_uuid = require_uuid(request.get("uuid"))
    summary = next((profile for profile in profile_summaries() if profile["uuid"] == profile_uuid), None)
    if not summary or summary.get("connectionType") != "802-11-wireless":
        raise ToolError("not_shareable", "The active Wi-Fi profile no longer exists")
    profile = get_profile_detail(summary)
    kind = security_kind(profile.get("security"))
    if kind == "enterprise":
        raise ToolError("not_shareable", "Enterprise Wi-Fi credentials cannot be shared")
    if kind in ("open", "owe"):
        return {"success": True, "password": "", "security": kind,
                "ssid": profile.get("ssid") or profile.get("name"), "hidden": profile.get("hidden", False)}
    result = run([
        "nmcli", "--show-secrets", "-g",
        "802-11-wireless-security.psk,802-11-wireless-security.wep-key0",
        "connection", "show", "uuid", profile_uuid,
    ], code="secret_unavailable", label="Stored Wi-Fi password", secret=True)
    values = [line for line in result.stdout.splitlines() if line and line != "--"]
    if not values:
        raise ToolError("secret_unavailable", "NetworkManager has no stored password for this profile")
    return {"success": True, "password": values[0], "security": kind,
            "ssid": profile.get("ssid") or profile.get("name"), "hidden": profile.get("hidden", False)}


def qr_escape(value: Any) -> str:
    output = str(value or "")
    for character in ("\\", ";", ",", ":", '"'):
        output = output.replace(character, "\\" + character)
    return output


def wifi_payload(ssid: str, security: str, password: str, hidden: bool = False) -> str:
    kind = security_kind(security)
    if kind == "enterprise":
        raise ToolError("not_shareable", "Enterprise Wi-Fi credentials cannot be shared")
    if kind == "unsupported":
        raise ToolError("not_shareable", "This Wi-Fi security method cannot be shared")
    qr_type = "WEP" if kind == "wep" else "WPA" if kind in ("wpa", "wpa3") else "nopass"
    parts = [f"WIFI:T:{qr_type}", f"S:{qr_escape(require_ssid(ssid))}"]
    if kind not in ("open", "owe"):
        parts.append(f"P:{qr_escape(credential(password, 'password', required=True))}")
    if hidden:
        parts.append("H:true")
    return ";".join(parts) + ";;"


def parse_qr_matrix(output: str) -> list[str]:
    stripped = output.strip("\r\n")
    if not stripped:
        raise ToolError("qr_failed", "qrencode returned an empty matrix")
    if stripped.startswith("["):
        try:
            rows = json.loads(stripped)
        except json.JSONDecodeError as error:
            raise ToolError("qr_failed", "qrencode returned malformed output") from error
        if isinstance(rows, list) and rows and all(isinstance(row, str)
                                                   and set(row) <= {"0", "1"} for row in rows):
            width = len(rows[0])
            if width and all(len(row) == width for row in rows):
                return rows
        raise ToolError("qr_failed", "qrencode returned malformed output")
    lines = stripped.splitlines()
    if lines and all(set(line) <= {"0", "1"} for line in lines):
        width = len(lines[0])
        if width and all(len(line) == width for line in lines):
            return lines
    width = max(len(line) for line in lines)
    if width < 2:
        raise ToolError("qr_failed", "qrencode returned malformed output")
    if width % 2:
        width += 1
    rows: list[str] = []
    for line in lines:
        padded = line.ljust(width)
        rows.append("".join("1" if padded[index:index + 2].strip() else "0"
                            for index in range(0, width, 2)))
    if not rows or any(len(row) != len(rows[0]) for row in rows):
        raise ToolError("qr_failed", "qrencode returned malformed output")
    return rows


def qr_action(request: dict[str, Any]) -> dict[str, Any]:
    # The shell only sends the profile UUID for its normal share flow. Resolve
    # the stored secret and generate the matrix in this one bounded process so
    # the password never has to make a stdout round-trip through QML. Explicit
    # password requests remain supported for fixture and standalone callers.
    details: dict[str, Any] = {}
    if request.get("uuid") and "password" not in request:
        details = password_action({"uuid": request.get("uuid")})
    ssid = request.get("ssid") or details.get("ssid")
    security = request.get("security") or details.get("security", "")
    password = request.get("password") if "password" in request else details.get("password", "")
    hidden = request.get("hidden") if "hidden" in request else details.get("hidden", False)
    payload = wifi_payload(
        require_ssid(ssid),
        str(security),
        credential(password, "password"),
        bool(hidden),
    )
    # The payload is stdin, never argv.  stdout is transformed into a matrix;
    # neither the payload nor password is included in the JSON response
    # unless the caller asks to `reveal` it: the hotspot's join card shows
    # the password beside the code for devices that cannot scan.
    result = run(["qrencode", "-t", "ASCII", "-m", "2", "-o", "-"],
                 input_text=payload, seconds=timeout("NETWORK_TOOL_QR_TIMEOUT", 5),
                 code="qr_failed", label="QR generation", secret=True)
    matrix = parse_qr_matrix(result.stdout)
    response = {"success": True, "matrix": matrix, "width": len(matrix[0]), "height": len(matrix)}
    if request.get("reveal") is True:
        response["password"] = password
    return response


# ---- VPN ----------------------------------------------------------------
# VPN-plugin (OpenVPN, OpenConnect, vpnc, SSH, ...) and WireGuard profiles.
# Connecting runs network_vpn_agent: NetworkManager asks it for secrets and it
# shows the VPN plugin's own sign-in dialog, so no secret reaches this helper's
# output, its arguments or the shell. Import hands the user's file to
# `nmcli connection import`; its contents are only sniffed for the format and
# nmcli's diagnostics are classified, never echoed, since a parser error can
# quote a line of the file.

def vpn_service_kind(service_type: str) -> str:
    return service_type.rsplit(".", 1)[-1].strip().lower() if service_type else ""


def add_vpn_kinds(vpns: list[dict[str, Any]]) -> None:
    """Name the plugin of every `vpn` profile with one extra nmcli read."""
    plugins = [vpn for vpn in vpns if vpn["type"] == "vpn" and UUID_RE.fullmatch(vpn["uuid"])]
    if not plugins:
        return
    argv = ["nmcli", "-t", "--escape", "yes", "-m", "multiline", "-f",
            "connection.uuid,vpn.service-type", "connection", "show"]
    for vpn in plugins:
        argv += ["uuid", vpn["uuid"]]
    result = run(argv, label="VPN plugin lookup", check=False)
    if result.returncode != 0:
        return
    services = {first(record, "connection.uuid"): first(record, "vpn.service-type")
                for record in multiline_records(result.stdout, "connection.uuid")}
    for vpn in plugins:
        kind = vpn_service_kind(services.get(vpn["uuid"], ""))
        if kind:
            vpn["kind"] = kind
            vpn["label"] = VPN_LABELS.get(kind, "VPN")


def vpn_profiles(*, kinds: bool = True) -> list[dict[str, Any]]:
    result = run(connection_list_command(), label="NetworkManager profile status")
    vpns = parse_vpn_profiles(result.stdout)
    if kinds:
        add_vpn_kinds(vpns)
    return vpns


def require_vpn(value: Any) -> dict[str, Any]:
    # Every action re-reads the profile: a request may only touch a profile
    # that is a VPN now, whatever UUID it names.
    profile_uuid = require_uuid(value)
    profile = next((vpn for vpn in vpn_profiles(kinds=False) if vpn["uuid"] == profile_uuid), None)
    if profile is None:
        raise ToolError("vpn_missing", "That VPN connection no longer exists")
    return profile


def import_source(value: Any) -> tuple[Path, str]:
    candidate = str(value or "")
    if not candidate or any(character in candidate for character in "\x00\n\r") or len(candidate) > 4096:
        raise ToolError("invalid_file", "Choose an OpenVPN (.ovpn) or WireGuard (.conf) file")
    path = Path(os.path.expanduser(candidate))
    suffix = path.suffix.lower()
    if not path.is_absolute() or suffix not in (".ovpn", ".conf"):
        raise ToolError("invalid_file", "Choose an OpenVPN (.ovpn) or WireGuard (.conf) file")
    try:
        mode = path.stat().st_mode
    except OSError as error:
        raise ToolError("unreadable_file", "This file could not be read") from error
    if not stat.S_ISREG(mode):
        raise ToolError("invalid_file", "Choose an OpenVPN (.ovpn) or WireGuard (.conf) file")
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_IMPORT_BYTES + 1)
    except OSError as error:
        raise ToolError("unreadable_file", "This file could not be read") from error
    if len(data) > MAX_IMPORT_BYTES:
        raise ToolError("invalid_file", "This file is too large to be a VPN configuration")
    return path, config_kind(suffix, data.decode("utf-8", errors="replace"))


def config_kind(suffix: str, text: str) -> str:
    if suffix == ".ovpn":
        return "openvpn"
    lines = [line.strip().lower() for line in text.splitlines()]
    if "[interface]" in lines and any(line.replace(" ", "").startswith("privatekey=") for line in lines):
        return "wireguard"
    if any(line.split(None, 1)[0] in OPENVPN_DIRECTIVES for line in lines if line):
        return "openvpn"
    raise ToolError("unsupported_file", "This file is neither a WireGuard nor an OpenVPN configuration")


def display_name(stem: str) -> str:
    name = "".join(character for character in stem if character.isprintable()).strip()
    return name[:64] or "VPN"


def wireguard_interface(stem: str) -> str:
    # nmcli names a WireGuard profile and its interface after the file, so
    # the file name must be a valid kernel interface name.
    name = re.sub(r"[^A-Za-z0-9_-]", "", stem)[:15]
    return name or "wg0"


def import_failure(stderr: str, kind: str) -> tuple[str, str]:
    text = stderr.lower()
    label = "WireGuard" if kind == "wireguard" else "OpenVPN"
    if "not authorized" in text or "insufficient privileges" in text:
        return "not_authorized", "You are not allowed to add network connections"
    if "permission denied" in text or "no such file" in text:
        return "unreadable_file", "This file could not be read"
    if "plugin" in text:
        return "vpn_plugin_missing", f"The {label} support for NetworkManager is not installed"
    return "import_failed", f"NetworkManager could not import this file as a {label} configuration"


def vpn_import(request: dict[str, Any]) -> dict[str, Any]:
    path, kind = import_source(request.get("path"))
    name = display_name(path.stem)
    target = path
    scratch: Path | None = None
    try:
        if kind == "wireguard" and (not KERNEL_IFNAME_RE.fullmatch(path.stem) or path.stem in (".", "..")
                                    or path.suffix != ".conf"):
            # A symlink under a valid name, not a copy: the private key is
            # never duplicated into a temporary file.
            scratch = Path(tempfile.mkdtemp(prefix="cybexos-vpn-import-"))
            target = scratch / f"{wireguard_interface(path.stem)}.conf"
            target.symlink_to(path)
        result = run(["nmcli", "connection", "import", "type", kind, "file", str(target)],
                     seconds=timeout("NETWORK_TOOL_ACTION_TIMEOUT", 20), label="VPN import", check=False)
    finally:
        if scratch is not None:
            shutil.rmtree(scratch, ignore_errors=True)
    if result.returncode != 0:
        raise ToolError(*import_failure(result.stderr, kind))
    profile_uuid = parse_added_uuid(result.stdout)
    if not UUID_RE.fullmatch(profile_uuid):
        raise ToolError("import_failed", "NetworkManager did not identify the imported connection")
    # A VPN starts from its switch. NetworkManager brings an imported
    # WireGuard profile up at once and would reconnect it at every boot.
    modifications = ["connection.autoconnect", "no"]
    if kind == "wireguard" and scratch is not None:
        modifications += ["connection.id", name]
    run(["nmcli", "connection", "modify", "uuid", profile_uuid, *modifications],
        label="VPN import settings", check=False)
    if kind == "wireguard":
        run(["nmcli", "connection", "down", "uuid", profile_uuid], label="VPN import", check=False)
    else:
        name = next((vpn["name"] for vpn in vpn_profiles(kinds=False) if vpn["uuid"] == profile_uuid), name)
    return {"success": True, "action": "import", "uuid": profile_uuid, "name": name, "kind": kind,
            "message": f"Imported {name}"}


def vpn_connect(profile: dict[str, Any]) -> dict[str, Any]:
    try:
        import network_vpn_agent
    except ImportError as error:
        raise ToolError("missing_dependency", "Python GObject bindings are required to connect a VPN") from error
    try:
        network_vpn_agent.activate(profile["uuid"], timeout("NETWORK_TOOL_VPN_TIMEOUT", 50))
    except network_vpn_agent.AgentError as error:
        raise ToolError(error.code, error.message) from error
    return {"success": True, "action": "connect", "uuid": profile["uuid"],
            "message": f"Connected to {profile['name']}"}


def vpn_action(request: dict[str, Any]) -> dict[str, Any]:
    action = str(request.get("action", "list"))
    if action in ("", "list", "status"):
        return {"success": True, "vpns": vpn_profiles()}
    if action == "import":
        return vpn_import(request)
    if action not in ("connect", "disconnect", "remove"):
        raise ToolError("invalid_request", "Unknown VPN action")
    profile = require_vpn(request.get("uuid"))
    if action == "connect":
        if profile["state"] == "activated":
            return {"success": True, "action": action, "uuid": profile["uuid"]}
        return vpn_connect(profile)
    if action == "disconnect":
        if profile["state"] in ("", "deactivating"):
            return {"success": True, "action": action, "uuid": profile["uuid"]}
        result = run(["nmcli", "--wait", "15", "connection", "down", "uuid", profile["uuid"]],
                     seconds=timeout("NETWORK_TOOL_ACTION_TIMEOUT", 20), label="VPN disconnect", check=False)
        if result.returncode != 0 and require_vpn(profile["uuid"])["state"] == "activated":
            raise ToolError("vpn_disconnect_failed", "The VPN could not be disconnected")
        return {"success": True, "action": action, "uuid": profile["uuid"],
                "message": f"Disconnected from {profile['name']}"}
    # Removal is permanent: the shell's second press is part of the request.
    if request.get("confirmed") is not True:
        raise ToolError("confirmation_required", "Confirm removing the VPN connection")
    result = run(["nmcli", "connection", "delete", "uuid", profile["uuid"]],
                 label="Remove VPN connection", check=False)
    if result.returncode != 0:
        raise ToolError("vpn_remove_failed", "The VPN connection could not be removed")
    return {"success": True, "action": action, "uuid": profile["uuid"],
            "message": f"Removed {profile['name']}"}


# ---- Hotspot ------------------------------------------------------------
# One managed access-point profile in shared mode. It is created with
# autoconnect off, so it never starts at boot; the switch starts it. The
# password is generated here and reaches nmcli only through passwd-file on
# stdin, exactly like a Wi-Fi password: NetworkManager stores it in the
# profile on the first activation, and later starts use the stored one.

def generate_password() -> str:
    return "-".join("".join(secure_choice(PASSWORD_ALPHABET) for _ in range(4)) for _ in range(4))


def default_hotspot_ssid() -> str:
    host = socket.gethostname().split(".", 1)[0].strip()
    if not host or host.lower() in ("localhost", "localhost-live"):
        return "CybexOS hotspot"
    name = f"{host} hotspot"
    while len(name.encode("utf-8")) > 32:
        host = host[:-1]
        name = f"{host} hotspot"
    return name


def parse_wifi_devices(output: str) -> list[dict[str, Any]]:
    devices: list[dict[str, Any]] = []
    for line in output.replace("\r\n", "\n").splitlines():
        if not line:
            continue
        values = split_escaped(line)
        if len(values) != 5:
            raise ToolError("invalid_nmcli", "NetworkManager returned a malformed device list")
        interface, kind, state, connection, profile_uuid = values
        if kind != "wifi" or not IFACE_RE.fullmatch(interface):
            continue
        devices.append({
            "interface": interface,
            "state": state.strip().lower(),
            "connected": state.strip().lower() == "connected",
            "connection": "" if connection == "--" else connection,
            "uuid": "" if profile_uuid == "--" else profile_uuid,
            "ap": None,
        })
    return devices


def wifi_devices() -> list[dict[str, Any]]:
    result = run(["nmcli", "-t", "--escape", "yes", "-f", "DEVICE,TYPE,STATE,CONNECTION,CON-UUID",
                  "device", "status"], label="Wi-Fi adapter lookup")
    devices = parse_wifi_devices(result.stdout)
    for device in devices:
        properties = run(["nmcli", "-t", "--escape", "yes", "-f", "WIFI-PROPERTIES.AP",
                          "device", "show", device["interface"]], label="Wi-Fi adapter lookup", check=False)
        if properties.returncode == 0:
            value = detail_record(properties.stdout).get("WIFI-PROPERTIES.AP", "").strip().lower()
            # Unknown stays None: the adapter may still manage, so let it try.
            device["ap"] = True if value == "yes" else False if value == "no" else None
    return devices


def choose_hotspot_device(devices: list[dict[str, Any]], active_interface: str = "") -> dict[str, Any] | None:
    if active_interface:
        current = next((device for device in devices if device["interface"] == active_interface), None)
        if current:
            return current
    capable = [device for device in devices if device["ap"] is not False]
    if not capable:
        return None
    # A second adapter that is not carrying a Wi-Fi connection can host the
    # hotspot without dropping the first; one that is off comes last.
    return sorted(capable, key=lambda device: (device["state"] == "unavailable", device["connected"]))[0]


def hotspot_record(records: list[dict[str, list[str]]]) -> dict[str, list[str]] | None:
    by_uuid = next((record for record in records if first(record, "UUID") == HOTSPOT_UUID), None)
    return by_uuid or next((record for record in records if first(record, "NAME") == HOTSPOT_NAME
                            and first(record, "TYPE") == "802-11-wireless"
                            and UUID_RE.fullmatch(first(record, "UUID"))), None)


def hotspot_status(records: list[dict[str, list[str]]] | None = None) -> dict[str, Any]:
    if records is None:
        records = multiline_records(run(connection_list_command(),
                                        label="NetworkManager profile status").stdout, "NAME")
    devices = wifi_devices()
    record = hotspot_record(records)
    state = connection_state(record) if record else ""
    active_interface = first(record, "DEVICE") if record and state else ""
    device = choose_hotspot_device(devices, "" if active_interface == "--" else active_interface)
    ssid = default_hotspot_ssid()
    profile_interface = ""
    if record:
        detail = run(["nmcli", "-t", "--escape", "yes", "-f", "802-11-wireless.ssid,connection.interface-name",
                      "connection", "show", "uuid", first(record, "UUID")],
                     label="Hotspot profile", check=False)
        if detail.returncode == 0:
            fields = detail_record(detail.stdout)
            ssid = fields.get("802-11-wireless.ssid") or ssid
            profile_interface = fields.get("connection.interface-name", "")
    hosting = bool(device and state in ("activated", "activating"))
    drops = bool(device and not hosting and device["connected"] and device["uuid"] != first(record or {}, "UUID"))
    return {
        "available": bool(devices),
        "supported": device is not None,
        "interface": device["interface"] if device else "",
        "profileInterface": profile_interface,
        "radioOff": bool(device and device["state"] == "unavailable" and not hosting),
        "configured": record is not None,
        "uuid": first(record, "UUID") if record else "",
        "ssid": ssid,
        "state": state,
        "active": state == "activated",
        "dropsWifi": drops,
        "wifiConnection": device["connection"] if drops and device else "",
    }


def create_hotspot(ssid: str, interface: str) -> str:
    result = run(["nmcli", "connection", "add", "type", "wifi", "ifname", require_interface(interface),
                  "con-name", HOTSPOT_NAME, "ssid", require_ssid(ssid), *HOTSPOT_SETTINGS],
                 code="hotspot_create_failed", label="Create hotspot profile")
    created = parse_added_uuid(result.stdout)
    return created if UUID_RE.fullmatch(created) else HOTSPOT_UUID


def hotspot_failure(stderr: str) -> tuple[str, str]:
    text = stderr.lower()
    if "not authorized" in text or "insufficient privileges" in text:
        return "not_authorized", "You are not allowed to start a hotspot"
    if "timeout" in text or "timed out" in text:
        return "hotspot_timeout", "The hotspot did not start in time"
    if "secrets were required" in text or "no secrets" in text:
        return "hotspot_secrets", "NetworkManager did not accept the hotspot password"
    if any(token in text for token in ("not available", "unavailable", "no suitable device", "not compatible")):
        return "hotspot_unavailable", "The Wi-Fi adapter is busy or cannot host a hotspot right now"
    return "hotspot_failed", "The hotspot could not start. The Wi-Fi adapter may not support it."


def start_hotspot(profile_uuid: str, interface: str) -> None:
    # A fresh password goes along every time; NetworkManager only asks for
    # it while the profile has none stored, so a saved one is kept.
    secret = f"802-11-wireless-security.psk:{generate_password()}\n"
    result = run(["nmcli", "--wait", "25", "connection", "up", "uuid", require_uuid(profile_uuid),
                  "ifname", require_interface(interface), "passwd-file", "/dev/stdin"],
                 input_text=secret, seconds=timeout("NETWORK_TOOL_ACTIVATE_TIMEOUT", 30),
                 label="Hotspot start", secret=True, check=False)
    if result.returncode != 0:
        raise ToolError(*hotspot_failure(result.stderr))


def hotspot_action(request: dict[str, Any]) -> dict[str, Any]:
    action = str(request.get("action", "status"))
    if action in ("", "status"):
        return {"success": True, **hotspot_status()}
    if action not in ("start", "stop", "rename"):
        raise ToolError("invalid_request", "Unknown hotspot action")
    status = hotspot_status()
    if action == "stop":
        if status["state"] in ("activated", "activating"):
            result = run(["nmcli", "--wait", "15", "connection", "down", "uuid", status["uuid"]],
                         seconds=timeout("NETWORK_TOOL_ACTION_TIMEOUT", 20), label="Hotspot stop", check=False)
            if result.returncode != 0 and hotspot_status()["state"] == "activated":
                raise ToolError("hotspot_stop_failed", "The hotspot could not be stopped")
        return {"success": True, "action": action, "message": "Hotspot stopped"}
    if not status["available"]:
        raise ToolError("no_wifi", "This computer has no Wi-Fi adapter")
    if not status["supported"]:
        raise ToolError("hotspot_unsupported", "This Wi-Fi adapter cannot host a hotspot")
    ssid = require_ssid(str(request.get("ssid") or status["ssid"]).strip())
    hosting = status["state"] in ("activated", "activating")
    if action == "start" and status["radioOff"]:
        raise ToolError("wifi_off", "Turn on Wi-Fi to start the hotspot")
    if not status["configured"]:
        profile_uuid = create_hotspot(ssid, status["interface"])
    else:
        profile_uuid = status["uuid"]
        changes: list[str] = []
        if ssid != status["ssid"]:
            changes += ["802-11-wireless.ssid", ssid]
        if action == "start" and status["profileInterface"] not in ("", status["interface"]):
            changes += ["connection.interface-name", status["interface"]]
        if changes:
            run(["nmcli", "connection", "modify", "uuid", profile_uuid, *changes],
                code="hotspot_modify_failed", label="Hotspot settings")
        elif hosting:
            return {"success": True, "action": action, "ssid": ssid, "uuid": profile_uuid}
    if action == "rename" and not hosting:
        return {"success": True, "action": action, "ssid": ssid, "message": f"Hotspot name set to {ssid}"}
    # A rename of a running hotspot restarts it under the new name.
    start_hotspot(profile_uuid, status["interface"])
    return {"success": True, "action": action, "ssid": ssid, "uuid": profile_uuid,
            "message": f"Hotspot {ssid} is on"}


def connection_extras() -> dict[str, Any]:
    """VPN profiles and hotspot state for Settings, from one profile list."""
    output = run(connection_list_command(), label="NetworkManager profile status").stdout
    vpns = parse_vpn_profiles(output)
    add_vpn_kinds(vpns)
    return {"vpns": vpns, "hotspot": hotspot_status(multiline_records(output, "NAME"))}


def main() -> None:
    parser = argparse.ArgumentParser(description="Quickshell network helper")
    parser.add_argument("command", choices=("snapshot", "wifi", "dns", "band", "password", "qr",
                                            "vpn", "hotspot"))
    arguments = parser.parse_args()
    if arguments.command == "snapshot":
        emit(snapshot())
    request = read_request()
    handlers = {
        "wifi": wifi_action,
        "dns": dns_action,
        "band": band_action,
        "password": password_action,
        "qr": qr_action,
        "vpn": vpn_action,
        "hotspot": hotspot_action,
    }
    emit(handlers[arguments.command](request))


if __name__ == "__main__":
    try:
        main()
    except ToolError as error:
        emit({"success": False, "error": error.message, "code": error.code}, 1)
    except KeyboardInterrupt:
        emit({"success": False, "error": "Canceled", "code": "canceled"}, 130)
    except Exception:
        # Unexpected exception details may contain command data.  Keep the
        # public contract stable and journal-safe; fixture tests exercise the
        # individual parsers directly when they need diagnostics.
        emit({"success": False, "error": "The network helper failed unexpectedly", "code": "internal"}, 1)
