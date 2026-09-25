import shutil

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import Gio, GObject, Nautilus  # noqa: E402


class SendViaLocalSendAction(GObject.GObject, Nautilus.MenuProvider):
    def _resolve_command(self):
        localsend = shutil.which("localsend")
        if not localsend:
            return None
        return [localsend]

    def _selected_paths(self, files):
        paths = []
        for file in files:
            location = file.get_location()
            if not location:
                continue

            path = location.get_path()
            if path and path not in paths:
                paths.append(path)

        return paths

    def _launch_localsend(self, paths):
        command = self._resolve_command()
        if command:
            Gio.Subprocess.new(command + paths, Gio.SubprocessFlags.NONE)

    def _on_activate(self, _menu, paths):
        self._launch_localsend(paths)

    def get_file_items(self, *args):
        files = args[0] if len(args) == 1 else args[1]
        paths = self._selected_paths(files)
        if not paths or not self._resolve_command():
            return []

        label = "Send via LocalSend" if len(paths) == 1 else "Send selected via LocalSend"
        item = Nautilus.MenuItem(
            name="LocalSendNautilus::send_via_localsend",
            label=label,
            icon="localsend",
        )
        item.connect("activate", self._on_activate, paths)
        return [item]
