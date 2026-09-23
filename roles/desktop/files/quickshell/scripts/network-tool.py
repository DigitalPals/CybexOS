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
import subprocess
import sys
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


def choose_primary(devices: list[dict[str, Any]], routes: list[dict[str, Any]]) -> dict[str, Any] | None:
    physical = [device for device in devices
                if device.get("type") in ("ethernet", "wifi") and device.get("connected")]
    by_interface = {device["interface"]: device for device in physical}
    candidates = [(route.get("metric", 2**31 - 1),
                   0 if by_interface.get(route.get("interface"), {}).get("type") == "ethernet" else 1,
                   route.get("interface", ""), by_interface[route["interface"]])
                  for route in routes if route.get("interface") in by_interface]
    if candidates:
        return sorted(candidates, key=lambda item: item[:3])[0][3]
    physical.sort(key=lambda device: (0 if device["type"] == "ethernet" else 1,
                                      device["interface"]))
    return physical[0] if physical else None


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


def ping_once(target: str) -> float | None:
    if not target:
        return None
    result = run(["ping", "-n", "-c", "1", "-W", "1", target],
                 seconds=timeout("NETWORK_TOOL_PING_TIMEOUT", 1.4), label="ping", check=False)
    if result.returncode != 0:
        return None
    match = re.search(r"time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms", result.stdout)
    return float(match.group(1)) if match else None


def wifi_scan(interface: str) -> subprocess.CompletedProcess[str]:
    return run([
        "nmcli", "-t", "--escape", "yes", "-f",
        "IN-USE,SSID,BSSID,SIGNAL,FREQ,SECURITY", "device", "wifi", "list",
        "ifname", interface, "--rescan", "no",
    ], seconds=timeout("NETWORK_TOOL_SCAN_TIMEOUT", 5), label="Wi-Fi scan", check=False)


def snapshot() -> dict[str, Any]:
    # The panel polls this every 1.5 seconds, so independent lookups run side
    # by side: the three NetworkManager/ip reads first, then the Wi-Fi scan,
    # link and both pings, which only need the first round's answers.
    # Results are collected in the old sequential order, so the first failure
    # reported, and the payload itself, are unchanged.
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
    profiles_future = executor.submit(run, [
        "nmcli", "-t", "--escape", "yes", "-m", "multiline", "-f",
        "NAME,UUID,TYPE,DEVICE", "connection", "show",
    ], label="NetworkManager profile status")
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
    # Nothing below changes a device's type, state or gateway, so the primary
    # interface and both ping targets are already settled here.
    primary = choose_primary(devices, routes)
    gateway = primary.get("gateway", "") if primary else ""
    internet_target = os.environ.get("NETWORK_TOOL_PING_TARGET", "1.1.1.1")
    scan_future = executor.submit(wifi_scan, wifi_device["interface"]) if wifi_device else None
    link_future = executor.submit(link_info, wifi_device["interface"]) if wifi_device else None
    router_future = executor.submit(ping_once, gateway) if gateway else None
    internet_future = executor.submit(ping_once, internet_target) if primary else None

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

    router_ping = router_future.result() if router_future else None
    internet_ping = internet_future.result() if internet_future else None

    return {
        "success": True,
        "timestamp": int(time.time() * 1000),
        "devices": devices,
        "routes": routes,
        "profiles": profiles,
        "wifi": {
            "interface": wifi_device["interface"] if wifi_device else "",
            "networks": networks,
            "link": link,
        },
        "diagnostics": {"routerPingMs": router_ping, "internetPingMs": internet_ping},
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


def profile_summaries() -> list[dict[str, Any]]:
    result = run([
        "nmcli", "-t", "--escape", "yes", "-m", "multiline", "-f",
        "NAME,UUID,TYPE,DEVICE", "connection", "show",
    ], label="NetworkManager profile status")
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
    return profile.get("connectionType") in PHYSICAL_TYPES and bool(profile.get("standalone", True))


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
    # neither the payload nor password is included in the JSON response.
    result = run(["qrencode", "-t", "ASCII", "-m", "2", "-o", "-"],
                 input_text=payload, seconds=timeout("NETWORK_TOOL_QR_TIMEOUT", 5),
                 code="qr_failed", label="QR generation", secret=True)
    matrix = parse_qr_matrix(result.stdout)
    return {"success": True, "matrix": matrix, "width": len(matrix[0]), "height": len(matrix)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Quickshell network helper")
    parser.add_argument("command", choices=("snapshot", "wifi", "dns", "band", "password", "qr"))
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
