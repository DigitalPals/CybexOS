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
import shutil
import subprocess
import plugin_packages
from urllib.parse import unquote


API_VERSION = 1
ID = re.compile(r"[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*\Z")
KINDS = {"bar-widget": "barWidget", "panel": "panel", "overlay": "overlay",
         "menu": "menu", "service": "service", "bar": "bar"}
PACKAGE_ID = re.compile(r"[A-Za-z][A-Za-z0-9_.-]*\Z")


def valid_id(plugin_id: str) -> bool:
    return isinstance(plugin_id, str) and bool(PACKAGE_ID.fullmatch(plugin_id)) and ".." not in plugin_id


def roots() -> tuple[Path, Path, Path]:
    home = Path.home()
    config = Path(os.environ.get("CYBEXOS_USER_CONFIG_ROOT") or
                  Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config") / "cybexos")
    packages = Path(os.environ.get("CYBEXOS_PLUGIN_ROOT") or
                    Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share") /
                    "cybexos/plugins")
    # Persistent plugin data is not disposable updater/diagnostic state. The
    # uninstaller may remove the latter while retaining user customizations.
    state = Path(os.environ.get("XDG_DATA_HOME") or home / ".local/share") / "cybexos/plugin-data"
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
    metadata = manifest.get("omarchy", {})
    if not isinstance(metadata, dict) or ("clonedFrom" in metadata and not valid_id(metadata["clonedFrom"])):
        raise ValueError("Invalid Omarchy clone metadata")
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
                                        "enabled": descriptor["enabled"] and widget_enabled and configured["enabled"], "section": section,
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
                instances[name] = {**previous, "enabled": True, "section": section, "order": order, "settings": settings}
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


def edit_layout(config: Path, packages: Path, state: Path, action: str, plugin_id: str, payload: dict) -> None:
    # Called under the preference lock: each queued IPC edit sees all earlier
    # writes, even when several arrive before the next discovery refresh.
    info = scan(config, packages, state)
    if info["error"]:
        raise ValueError(info["error"])
    item = next((item for item in info["plugins"] if item["id"] == plugin_id and not item["error"]), None)
    if not item or item["format"] != "omarchy" or "bar-widget" not in item["kinds"]:
        raise ValueError("Unknown Omarchy widget")
    layout = {section: [] for section in ("left", "center", "right")}
    for widget in info["widgets"]:
        if widget["enabled"] and not widget["error"] and widget["format"] == "omarchy":
            layout[widget["section"]].append({**widget["settings"], "id": widget["id"],
                                               "__cybexInstance": widget.get("instanceName", "")})
    selector = payload.get("selector", {}) if action == "set" else payload
    if not isinstance(selector, dict):
        raise ValueError("Invalid selector")
    source_section = selector.get("fromSection", selector.get("section") if action == "set" else None)
    source_index = selector.get("fromIndex", selector.get("index") if action == "set" else None)
    if source_index is not None and (not source_section or type(source_index) is not int or source_index < 0):
        raise ValueError("Invalid source index")
    found = None
    for section, entries in layout.items():
        if source_section and section != source_section:
            continue
        for index, entry in enumerate(entries):
            if entry["id"] == plugin_id and (source_index is None or source_index == index):
                found = (section, index, entry)
                break
        if found:
            break
    if action == "put" and found:
        return
    if action in ("set", "move") and not found:
        raise ValueError("Widget not found at source position")
    if action == "set":
        if not isinstance(payload.get("key"), str) or "value" not in payload:
            raise ValueError("Setting mutation needs key and value")
        if payload["key"] in ("id", "__cybexInstance"):
            raise ValueError("Cannot change widget identity")
        found[2][payload["key"]] = payload["value"]
    else:
        section = payload.get("section", found[0] if found else item["section"])
        if section not in layout:
            raise ValueError("Invalid section")
        if payload.get("before") and payload.get("after"):
            raise ValueError("Choose before or after")
        entry = layout[found[0]].pop(found[1]) if found else {**item["settings"], "id": plugin_id}
        index = payload.get("index", len(layout[section]))
        relative = payload.get("before", payload.get("after"))
        if relative:
            anchor = next(((name, at) for name, entries in layout.items()
                           for at, candidate in enumerate(entries) if candidate["id"] == relative
                           and (not payload.get("section") or name == section)), None)
            if anchor:
                section, index = anchor
                index += bool(payload.get("after"))
            elif action != "put":
                raise ValueError("Relative widget not found")
        if type(index) is not int or not 0 <= index <= len(layout[section]):
            raise ValueError("Invalid index")
        layout[section].insert(index, entry)
    value = preferences(config)
    apply_layout(value, layout, packages)
    write_preferences(config, value)


def runtime_sources(result: dict, packages: Path, runtime: Path) -> None:
    for item in result["plugins"]:
        if item.get("error") or not item.get("enabled"):
            continue
        source = packages / item["id"]
        revision = plugin_packages.fingerprint(source)
        destination = runtime / item["id"] / revision
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".snapshot-", dir=destination.parent) as temporary:
                staged = Path(temporary) / "code"
                shutil.copytree(source, staged, symlinks=True, ignore=shutil.ignore_patterns(".git"))
                if plugin_packages.fingerprint(source) != revision:
                    raise ValueError("Plugin changed during scan; retrying on next refresh")
                staged.rename(destination)
        original = source.resolve()
        item["sources"] = {kind: (destination / Path(unquote(url.removeprefix("file://"))).relative_to(original)).as_uri()
                           for kind, url in item["sources"].items()}
        item["source"] = item["sources"].get("barWidget", "")
        for widget in result["widgets"]:
            if widget["id"] == item["id"]:
                widget["sources"] = item["sources"]
                widget["source"] = item["source"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    configure = commands.add_parser("configure-widget", help="Change one widget without disabling its plugin services")
    configure.add_argument("key")
    configure.add_argument("value")
    move = commands.add_parser("move-widget", help="Move a native bar plugin widget, preserving its settings")
    move.add_argument("key")
    move.add_argument("section", choices=("left", "center", "right"))
    move.add_argument("index", type=int)
    layout_edit = commands.add_parser("layout-edit", help="Apply one atomic IPC layout mutation")
    layout_edit.add_argument("action", choices=("enable", "put", "move", "set"))
    layout_edit.add_argument("id")
    layout_edit.add_argument("payload")
    bar_config = commands.add_parser("bar-config", help="Persist replacement bar settings and widget layout")
    bar_config.add_argument("value")
    listing = commands.add_parser("list", help="Inspect installed widgets and compatibility as JSON")
    listing.add_argument("--runtime-root", type=Path)
    listing.add_argument("--live", action="store_true")
    add = commands.add_parser("add", help="Install a trusted Git package (disabled until enabled)")
    add.add_argument("source")
    update = commands.add_parser("update", help="Validate and fast-forward a clean Git checkout")
    update.add_argument("id")
    update.add_argument("--preview", action="store_true")
    remove = commands.add_parser("remove", help="Remove package files, preserving settings and data")
    remove.add_argument("id")
    clone = commands.add_parser("clone", help="Customize an installed package under a new ID")
    clone.add_argument("id")
    clone.add_argument("new_id")
    clone.add_argument("--edit", action="store_true")
    clone.add_argument("--from", dest="builtin_root", type=Path, help="Omarchy checkout containing built-in sources")
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
            with locked(config):
                result = scan(config, packages, state)
                if args.live:
                    owner = os.getppid()
                    session = str(owner) + "-" + Path(f"/proc/{owner}/stat").read_text().rsplit(")", 1)[1].split()[19]
                    cache = Path(os.environ["XDG_RUNTIME_DIR"]) / "cybex-plugin-code"
                    cache.mkdir(mode=0o700, exist_ok=True)
                    for old in cache.iterdir():
                        if not old.is_dir() or old.is_symlink():
                            continue
                        pid, _, stamp = old.name.partition("-")
                        try:
                            current = Path(f"/proc/{int(pid)}/stat").read_text().rsplit(")", 1)[1].split()[19]
                        except (OSError, ValueError):
                            current = ""
                        if current != stamp:
                            shutil.rmtree(old)
                    args.runtime_root = cache / session
                if args.runtime_root:
                    runtime_sources(result, packages, args.runtime_root)
            print(json.dumps(result, ensure_ascii=False))
            return 0
        if args.command == "layout-edit":
            payload = json.loads(args.payload)
            if not isinstance(payload, dict) or not valid_id(args.id):
                raise ValueError("Invalid layout mutation")
            with locked(config):
                edit_layout(config, packages, state, args.action, args.id, payload)
            return 0
        if args.command == "add":
            with locked(config):
                value = preferences(config)
                plugin_id = plugin_packages.install(packages, args.source, package, read_object)
                try:
                    entry = value["plugins"].setdefault(plugin_id, {})
                    if not isinstance(entry, dict):
                        raise ValueError("Plugin preferences must be an object")
                    entry["enabled"] = False
                    write_preferences(config, value)
                except (OSError, ValueError):
                    shutil.rmtree(packages / plugin_id)
                    raise
                print(plugin_id)
            return 0
        if args.command in ("update", "remove", "clone"):
            if not valid_id(args.id):
                raise ValueError("Invalid plugin id")
            with locked(config):
                if args.command == "update":
                    print(plugin_packages.update(packages, args.id, package, args.preview))
                elif args.command == "clone":
                    if not valid_id(args.new_id):
                        raise ValueError("Invalid clone id")
                    value = preferences(config)
                    original = value["plugins"].get(args.id, {})
                    options(original)
                    plugin_packages.clone(packages, args.id, args.new_id, package, read_object, args.builtin_root)
                    cloned = json.loads(json.dumps(original))
                    cloned["enabled"] = True
                    cloned["cloneRestore"] = {"id": args.id, "enabled": original.get("enabled", False),
                                               "bar": value.get("bar", {}).get("id") == args.id}
                    value["plugins"][args.new_id] = cloned
                    if args.id in value["plugins"]:
                        value["plugins"][args.id]["enabled"] = False
                    if cloned["cloneRestore"]["bar"]:
                        value["bar"]["id"] = args.new_id
                    try:
                        write_preferences(config, value)
                    except (OSError, ValueError):
                        shutil.rmtree(packages / args.new_id)
                        raise
                else:
                    directory = plugin_packages.managed_directory(packages, args.id)
                    value = preferences(config)
                    removed = value["plugins"].setdefault(args.id, {})
                    if not isinstance(removed, dict):
                        raise ValueError("Plugin preferences must be an object")
                    restore = removed.pop("cloneRestore", {})
                    if not isinstance(restore, dict):
                        raise ValueError("Invalid clone restoration metadata")
                    if restore.get("id") in value["plugins"]:
                        original = value["plugins"][restore["id"]]
                        if not isinstance(original, dict) or type(restore.get("enabled")) is not bool:
                            raise ValueError("Invalid original plugin preferences")
                        original["enabled"] = restore["enabled"]
                    removed["enabled"] = False
                    if value.get("bar", {}).get("id") == args.id:
                        value["bar"]["id"] = restore.get("id", "") if restore.get("bar") else ""
                    write_preferences(config, value)
                    shutil.rmtree(directory)
            if args.command == "clone" and args.edit:
                import shlex
                subprocess.run([*shlex.split(os.environ.get("EDITOR", "vi")),
                                str(packages / args.new_id / "manifest.json")], check=True)
            return 0
        if args.command == "configure-widget":
            changes = json.loads(args.value)
            if not isinstance(changes, dict) or not changes or set(changes) - {"enabled", "width", "section"}:
                raise ValueError("Widget changes must contain enabled, width or section")
            if "section" in changes and (changes["section"] not in ("left", "center", "right") or changes.get("enabled") is not True):
                raise ValueError("A section can only be chosen when adding a widget")
            if "enabled" in changes and type(changes["enabled"]) is not bool:
                raise ValueError("enabled must be a boolean")
            if "width" in changes and (type(changes["width"]) is not int or not 24 <= changes["width"] <= 320):
                raise ValueError("width must be an integer from 24 to 320")
            with locked(config):
                snapshot = scan(config, packages, state)
                if snapshot["error"]:
                    raise ValueError(snapshot["error"])
                widget = next((item for item in snapshot["widgets"] if item["key"] == args.key), None)
                if widget is None:
                    raise ValueError("Widget is no longer installed")
                if changes.get("enabled") and widget["error"]:
                    raise ValueError(widget["error"])
                value = preferences(config)
                entry = value["plugins"].setdefault(widget["id"], {})
                target = entry
                if widget["instanceName"]:
                    target = entry["instances"][widget["instanceName"]]
                if "width" in changes:
                    target["width"] = changes["width"]
                if "section" in changes:
                    # Enable and place atomically, including disabled instances.
                    # Keep every existing destination widget in its current order.
                    peers = [item for item in snapshot["widgets"] if item["enabled"]
                             and item["key"] != widget["key"] and item.get("section", "right") == changes["section"]]
                    for order, peer in enumerate(peers):
                        peer_target = value["plugins"].setdefault(peer["id"], {})
                        if peer["instanceName"]:
                            peer_target = peer_target["instances"][peer["instanceName"]]
                        peer_target["order"] = order
                    target.update(section=changes["section"], order=len(peers))
                if "enabled" in changes:
                    if widget["instanceName"]:
                        target["enabled"] = changes["enabled"]
                    else:
                        entry["widgetEnabled"] = changes["enabled"]
                    if changes["enabled"]:
                        entry["enabled"] = True
                        entry["widgetEnabled"] = True
                        (state / widget["id"]).mkdir(parents=True, exist_ok=True)
                write_preferences(config, value)
            return 0
        if args.command == "move-widget":
            with locked(config):
                snapshot = scan(config, packages, state)
                if snapshot["error"]:
                    raise ValueError(snapshot["error"])
                widgets = [item for item in snapshot["widgets"] if item["enabled"]]
                moving = next((item for item in widgets if item["key"] == args.key), None)
                if moving is None:
                    raise ValueError("Widget is no longer enabled")
                destination = [item for item in widgets if item.get("section", "right") == args.section]
                if not 0 <= args.index <= len(destination):
                    raise ValueError("Invalid widget drop index")
                index = args.index
                if moving in destination:
                    old_index = destination.index(moving)
                    destination.remove(moving)
                    if old_index < index:
                        index -= 1
                destination.insert(index, moving)
                value = preferences(config)
                for order, widget in enumerate(destination):
                    entry = value["plugins"][widget["id"]]
                    if widget["instanceName"]:
                        entry = entry["instances"][widget["instanceName"]]
                    entry.update(section=args.section, order=order)
                write_preferences(config, value)
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
                candidate = package(packages, args.id)
                origin = candidate["manifest"].get("omarchy", {}).get("clonedFrom", args.id)
                for other_id, other in value["plugins"].items():
                    if other_id == args.id or not isinstance(other, dict):
                        continue
                    try:
                        related = package(packages, other_id)["manifest"].get("omarchy", {}).get("clonedFrom")
                    except (OSError, ValueError):
                        continue
                    if other_id == origin or related == origin:
                        other["enabled"] = False
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
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(2, f"user-plugins: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
