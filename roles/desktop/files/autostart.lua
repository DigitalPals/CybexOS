hl.on("hyprland.start", function()
  -- One process serializes environment publication, target activation, and
  -- portal refresh. Separate async execs race target units against a partially
  -- imported environment on a fresh login.
  hl.exec_cmd([[/usr/local/libexec/cybexos-hyprland-session-start]])
end)
