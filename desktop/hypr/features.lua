return {
  podman = os.getenv("NERDOS_PODMAN") == "1", developer_tools = os.getenv("NERDOS_DEVELOPER_TOOLS") ~= "0",
  connected_widgets = os.getenv("NERDOS_CONNECTED_WIDGETS") ~= "0",
  private_portal = false, proprietary_apps = os.getenv("NERDOS_PROPRIETARY_APPS") == "1",
  xps_2026 = os.getenv("NERDOS_XPS_2026") == "1",
}
