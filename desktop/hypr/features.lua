return {
  podman = os.getenv("CYBEXOS_PODMAN") == "1", developer_tools = os.getenv("CYBEXOS_DEVELOPER_TOOLS") ~= "0",
  connected_widgets = os.getenv("CYBEXOS_CONNECTED_WIDGETS") ~= "0",
  private_portal = false, proprietary_apps = os.getenv("CYBEXOS_PROPRIETARY_APPS") == "1",
  xps_2026 = os.getenv("CYBEXOS_XPS_2026") == "1",
}
