#!/usr/bin/env python3
"""User-owned widget packages and preferences; no release-tree writes."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile


API_VERSION = 1
ID = re.compile(r"[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*\Z")
KINDS = {"bar-widget": "barWidget", "panel": "panel", "overlay": "overlay",
         "menu": "menu", "service": "service", "bar": "bar"}
PACKAGE_ID = re.compile(r"[A-Za-z][A-Za-z0-9_.-]*\Z")


def valid_id(plugin_id: str) -> bool:
    return isinstance(plugin_id, str) and bool(PACKAGE_ID.fullmatch(plugin_id)) and ".." not in plugin_id


def roots() -> tuple[Path, Path, Path]:
    home = Path.home()
    config = Path(os.environ.get("FEDORA_CONFIG_USER_CONFIG_ROOT") or
                  Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "fedora-config")
    packages = Path(os.environ.get("FEDORA_CONFIG_PLUGIN_ROOT") or
                    Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share") /
                    "fedora-config/plugins")
    # Persistent plugin data is not disposable updater/diagnostic state. The
    # uninstaller may remove the latter while retaining user customizations.
    state = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share") / "fedora-config/plugin-data"
    return config / "plugins.json", packages, state


def read_object(path: Path) -> dict:
    if path.stat().st_size > 1024 * 1024:
        raise ValueError(f"{path.name} exceeds 1 MiB")
    value = json.loads(path.read_text(encoding="utf-8"))
    json.dumps(value, allow_nan=False)
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    return value


def preferences(path: Path) -> dict:
    try:
        value = read_object(path)
    except FileNotFoundError:
        return {"v": 1, "plugins": {}}
    if type(value.get("v")) is not int or value["v"] != 1:
        raise ValueError("Unsupported plugins.json version; preferences were preserved")
    if not isinstance(value.get("plugins"), dict):
        raise ValueError("plugins.json must have a plugins object")
    return value


def package(packages: Path, plugin_id: str) -> dict:
    if not valid_id(plugin_id):
        raise ValueError("Invalid plugin id (use letters, digits, dots, underscores or hyphens)")
    directory = packages / plugin_id
    manifest = read_object(directory / "manifest.json")
    if manifest.get("id") != plugin_id:
        raise ValueError("Manifest id must match its directory name")
    omarchy = "schemaVersion" in manifest
    defaults = {}
    kinds = ["bar-widget"]
    if omarchy:
        if "apiVersion" in manifest:
            raise ValueError("Manifest cannot mix native and Omarchy formats")
        if type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1:
            raise ValueError("Unsupported Omarchy schemaVersion; host supports 1")
        kinds = manifest.get("kinds")
        if (not isinstance(kinds, list) or not kinds
                or any(not isinstance(kind, str) or kind not in KINDS for kind in kinds)
                or len(set(kinds)) != len(kinds)):
            raise ValueError("Unsupported or duplicate Omarchy plugin kind")
        entries = manifest.get("entryPoints")
        if not isinstance(entries, dict) or set(entries) != {KINDS[kind] for kind in kinds}:
            raise ValueError("Omarchy entryPoints must match the declared kinds")
        if "keepLoaded" in manifest and type(manifest["keepLoaded"]) is not bool:
            raise ValueError("keepLoaded must be a boolean")
        widget = manifest.get("barWidget", {})
        if not isinstance(widget, dict) or not isinstance(widget.get("defaults", {}), dict):
            raise ValueError("Omarchy barWidget and defaults must be objects")
        if "allowMultiple" in widget and type(widget["allowMultiple"]) is not bool:
            raise ValueError("barWidget.allowMultiple must be a boolean")
        defaults = widget.get("defaults", {})
        if widget.get("defaultSection", "center") not in ("left", "center", "right"):
            raise ValueError("Invalid barWidget.defaultSection")
    else:
        if not ID.fullmatch(plugin_id):
            raise ValueError("Native plugin ids must use lowercase letters, digits, dots or hyphens")
        if type(manifest.get("apiVersion")) is not int or manifest["apiVersion"] != API_VERSION:
            raise ValueError(f"Unsupported widget API {manifest.get('apiVersion')}; host supports 1")
        entries = {"barWidget": manifest.get("entrypoint")}
    for key in ("name", "version"):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            raise ValueError(f"Manifest needs a nonempty {key}")
    sources = {}
    for kind, entrypoint in entries.items():
        if not isinstance(entrypoint, str) or not entrypoint.strip():
            raise ValueError("Manifest needs a nonempty QML entrypoint")
        entry = Path(entrypoint)
        if entry.is_absolute() or ".." in entry.parts or entry.suffix != ".qml":
            raise ValueError("Entrypoint must be a relative .qml path inside the package")
        source = (directory / entry).resolve()
        if not source.is_relative_to(directory.resolve()) or not source.is_file():
            raise ValueError("Entrypoint is missing or resolves outside the package")
        sources[kind] = source.as_uri()
    public = {key: value for key, value in manifest.items() if not key.startswith("__")}
    public["__sourceDir"] = str(directory.resolve())
    public["__isFirstParty"] = False
    public["__hostCapabilities"] = []
    return {"id": plugin_id, "name": manifest["name"], "version": manifest["version"],
            "source": sources.get("barWidget", ""), "sources": sources, "kinds": kinds,
            "manifest": public, "keepLoaded": manifest.get("keepLoaded", False),
            "packagePath": str(directory.resolve()),
            "section": manifest.get("barWidget", {}).get("defaultSection", "center") if omarchy else "right",
            "format": "omarchy" if omarchy else "native", "defaults": defaults}


def options(value: object) -> dict:
    if not isinstance(value, dict):
        raise ValueError("Plugin preferences must be an object")
    enabled = value.get("enabled", False)
    width = value.get("width", 120)
    order = value.get("order", 0)
    settings = value.get("settings", {})
    if type(enabled) is not bool:
        raise ValueError("enabled must be a boolean")
    if type(width) is not int or not 24 <= width <= 320:
        raise ValueError("width must be an integer from 24 to 320")
    if type(order) is not int:
        raise ValueError("order must be an integer")
    if not isinstance(settings, dict):
        raise ValueError("settings must be an object")
    return {"enabled": enabled, "width": width, "order": order, "settings": settings}


def scan(config: Path, packages: Path, state: Path) -> dict:
    try:
        registry = preferences(config)
        saved = registry["plugins"]
        bar = registry.get("bar", {})
        if not isinstance(bar, dict) or bar.get("position", "top") not in ("top", "bottom", "left", "right"):
            raise ValueError("Invalid replacement bar configuration")
    except (OSError, ValueError) as error:
        return {"apiVersion": API_VERSION, "error": str(error), "plugins": []}
    found = set(saved)
    try:
        found.update(path.name for path in packages.iterdir()
                     if path.is_dir() and not path.name.startswith("."))
    except FileNotFoundError:
        pass
    result = []
    widgets = []
    for plugin_id in sorted(found):
        descriptor = {"id": plugin_id, "name": plugin_id, "enabled": False,
                      "order": 0, "width": 120, "settings": {}, "error": ""}
        try:
            descriptor.update(options(saved.get(plugin_id, {})))
            descriptor.update(package(packages, plugin_id))
            descriptor["settings"] = {**descriptor["defaults"], **descriptor["settings"]}
            descriptor["section"] = saved.get(plugin_id, {}).get("section", descriptor["section"])
            if descriptor["section"] not in ("left", "center", "right"):
                raise ValueError("section must be left, center or right")
            descriptor["dataPath"] = str(state / plugin_id)
            instances = saved.get(plugin_id, {}).get("instances", {})
            if not isinstance(instances, dict):
                raise ValueError("instances must be an object")
            if instances and not descriptor["manifest"].get("barWidget", {}).get("allowMultiple", False):
                raise ValueError("Plugin does not allow multiple instances")
            if "bar-widget" in descriptor["kinds"]:
                widget_enabled = saved.get(plugin_id, {}).get("widgetEnabled", True)
                if type(widget_enabled) is not bool:
                    raise ValueError("widgetEnabled must be a boolean")
                if not instances:
                    widgets.append({**descriptor, "key": plugin_id, "instanceName": "",
                                    "enabled": descriptor["enabled"] and widget_enabled})
                else:
                    pending = []
                    for name, instance in instances.items():
                        if not valid_id(name) or not isinstance(instance, dict):
                            raise ValueError("Invalid widget instance")
                        inherited = {**saved.get(plugin_id, {}), **instance}
                        configured = options(inherited)
                        section = instance.get("section", descriptor["section"])
                        if section not in ("left", "center", "right"):
                            raise ValueError("Invalid instance section")
                        pending.append({**descriptor, **configured, "id": plugin_id,
                                        "key": plugin_id + "#" + name, "instanceName": name,
                                        "enabled": descriptor["enabled"] and widget_enabled, "section": section,
                                        "settings": {**descriptor["settings"], **configured["settings"]}})
                    widgets.extend(pending)
        except (OSError, ValueError) as error:
            descriptor["error"] = str(error)
            if descriptor["enabled"]:
                widgets.append({**descriptor, "key": plugin_id, "instanceName": ""})
        result.append(descriptor)
    return {"apiVersion": API_VERSION, "error": "", "bar": bar,
            "widgets": sorted(widgets, key=lambda item: (item["order"], item["key"])),
            "plugins": sorted(result, key=lambda item: (item["order"], item["id"]))}


@contextmanager
def locked(config: Path):
    config.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW
    with os.fdopen(os.open(str(config) + ".lock", flags, 0o600), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if config.is_symlink():
            raise ValueError("Refusing to replace a symlinked plugins.json")
        yield


def write_preferences(config: Path, value: dict) -> None:
    # Preserve unknown fields, even when written by a newer compatible host.
    encoded = json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if len(encoded.encode("utf-8")) > 1024 * 1024:
        raise ValueError("plugins.json would exceed 1 MiB; store large data in the plugin data directory")
    descriptor, temporary = tempfile.mkstemp(prefix=".plugins-", dir=config.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, config)
        directory = os.open(config.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply_layout(registry: dict, layout: object, packages: Path) -> None:
    if not isinstance(layout, dict) or set(layout) != {"left", "center", "right"}:
        raise ValueError("layout must contain left, center and right arrays")
    grouped = {}
    for section, entries in layout.items():
        if not isinstance(entries, list):
            raise ValueError("layout sections must be arrays")
        for order, item in enumerate(entries):
            if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                raise ValueError("layout entries must contain an id")
            grouped.setdefault(item["id"], []).append((section, order, item))
    for plugin_id, rows in grouped.items():
        candidate = package(packages, plugin_id)
        if candidate["format"] != "omarchy" or "bar-widget" not in candidate["kinds"]:
            raise ValueError("Replacement layout entry is not an Omarchy widget")
        multiple = candidate["manifest"].get("barWidget", {}).get("allowMultiple", False)
        if len(rows) > 1 and not multiple:
            raise ValueError("Plugin does not allow multiple instances")
        saved = registry["plugins"].setdefault(plugin_id, {})
        if not isinstance(saved, dict):
            raise ValueError("Plugin preferences must be an object")
        saved.update(enabled=True, widgetEnabled=True)
        previous_instances = saved.get("instances", {})
        if not isinstance(previous_instances, dict):
            raise ValueError("instances must be an object")
        instances = {}
        for section, order, item in rows:
            name = item.get("__cybexInstance", "")
            if not name and len(rows) > 1:
                name = "instance" + str(len(instances) + 1)
            if name and (not multiple or not valid_id(name) or name in instances):
                raise ValueError("Invalid or duplicate widget instance name")
            settings = {key: data for key, data in item.items() if key not in ("id", "__cybexInstance")}
            if name:
                previous = previous_instances.get(name, {})
                if not isinstance(previous, dict):
                    raise ValueError("Instance must be an object")
                instances[name] = {**previous, "section": section, "order": order, "settings": settings}
                options({**saved, **instances[name]})
            else:
                saved.update(section=section, order=order, settings=settings)
        if instances or "instances" in saved:
            saved["instances"] = instances
        options(saved)
    # Layout removal hides the widget while retaining its service and settings.
    for plugin_id, saved in registry["plugins"].items():
        if plugin_id in grouped or not isinstance(saved, dict):
            continue
        try:
            candidate = package(packages, plugin_id)
        except (OSError, ValueError):
            continue
        if candidate["format"] == "omarchy" and "bar-widget" in candidate["kinds"]:
            saved["widgetEnabled"] = False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bar_config = commands.add_parser("bar-config", help="Persist replacement bar settings and widget layout")
    bar_config.add_argument("value")
    commands.add_parser("list", help="Inspect installed widgets and compatibility as JSON")
    enable = commands.add_parser("enable", help="Enable a trusted local widget")
    enable.add_argument("id")
    enable.add_argument("--width", type=int)
    enable.add_argument("--order", type=int)
    enable.add_argument("--section", choices=("left", "center", "right"))
    merge = commands.add_parser("merge", help="Atomically merge plugin settings from a JSON object")
    merge.add_argument("id")
    merge.add_argument("value")
    merge.add_argument("--instance")
    instance = commands.add_parser("instance", help="Create or configure a named widget instance")
    instance.add_argument("id")
    instance.add_argument("name")
    instance.add_argument("--section", choices=("left", "center", "right"))
    instance.add_argument("--width", type=int)
    instance.add_argument("--order", type=int)
    instance.add_argument("--remove", action="store_true")
    bar = commands.add_parser("bar", help="Select a replacement bar, or native to restore Cybex")
    bar.add_argument("id")
    bar.add_argument("--position", choices=("top", "bottom", "left", "right"))
    disable = commands.add_parser("disable", help="Disable a widget, retaining its files and settings")
    disable.add_argument("id")
    setting = commands.add_parser("set", help="Set one widget setting to a JSON value")
    setting.add_argument("id")
    setting.add_argument("key")
    setting.add_argument("value")
    setting.add_argument("--instance")
    args = parser.parse_args()
    config, packages, state = roots()
    try:
        if args.command == "list":
            print(json.dumps(scan(config, packages, state), ensure_ascii=False))
            return 0
        if args.command == "bar-config":
            incoming = json.loads(args.value)
            if not isinstance(incoming, dict) or incoming.get("position", "top") not in ("top", "bottom", "left", "right"):
                raise ValueError("Invalid replacement bar configuration")
            with locked(config):
                value = preferences(config)
                # A bar can edit its presentation and plugin layout, not select
                # another executable or overwrite native shell settings.
                current = value.setdefault("bar", {})
                if not isinstance(current, dict):
                    raise ValueError("bar must be an object")
                current.update({key: item for key, item in incoming.items() if key not in ("id", "layout")})
                if "layout" in incoming:
                    apply_layout(value, incoming["layout"], packages)
                write_preferences(config, value)
            return 0
        if not valid_id(args.id):
            raise ValueError("Invalid plugin id")
        with locked(config):
            value = preferences(config)
            if args.command == "bar":
                if args.id != "native":
                    candidate = package(packages, args.id)
                    if "bar" not in candidate["kinds"]:
                        raise ValueError("Selected plugin does not declare a bar")
                    value["plugins"].setdefault(args.id, {})["enabled"] = True
                current = value.setdefault("bar", {})
                if not isinstance(current, dict):
                    raise ValueError("bar must be an object")
                current["id"] = "" if args.id == "native" else args.id
                if args.position:
                    current["position"] = args.position
                write_preferences(config, value)
                return 0
            entry = value["plugins"].setdefault(args.id, {})
            if not isinstance(entry, dict):
                raise ValueError("Plugin preferences must be an object")
            if args.command == "instance":
                if not valid_id(args.name):
                    raise ValueError("Invalid instance name")
                instances = entry.setdefault("instances", {})
                if not isinstance(instances, dict):
                    raise ValueError("instances must be an object")
                if args.remove:
                    instances.pop(args.name, None)
                else:
                    candidate = package(packages, args.id)
                    if not candidate["manifest"].get("barWidget", {}).get("allowMultiple", False):
                        raise ValueError("Plugin does not allow multiple instances")
                    configured = instances.setdefault(args.name, {})
                    if not isinstance(configured, dict):
                        raise ValueError("Instance must be an object")
                    for key in ("section", "width", "order"):
                        if getattr(args, key) is not None:
                            configured[key] = getattr(args, key)
                    options({**entry, **configured})
            elif args.command == "enable":
                package(packages, args.id)
                entry["enabled"] = True
                entry["widgetEnabled"] = True
                for key in ("width", "order", "section"):
                    if getattr(args, key) is not None:
                        entry[key] = getattr(args, key)
                options(entry)
                (state / args.id).mkdir(parents=True, exist_ok=True)
            elif args.command == "disable":
                entry["enabled"] = False
            else:
                target = entry
                if args.instance:
                    target = entry.get("instances", {}).get(args.instance)
                    if not isinstance(target, dict):
                        raise ValueError("Unknown instance; create it with the instance command")
                settings = target.setdefault("settings", {})
                if not isinstance(settings, dict):
                    raise ValueError("Plugin settings must be an object")
                if args.command == "merge":
                    patch = json.loads(args.value)
                    if not isinstance(patch, dict):
                        raise ValueError("Settings patch must be a JSON object")
                    settings.update({key: item for key, item in patch.items() if key != "id"})
                else:
                    settings[args.key] = json.loads(args.value)
                options(entry)
            write_preferences(config, value)
        return 0
    except (OSError, ValueError) as error:
        parser.exit(2, f"user-plugins: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
