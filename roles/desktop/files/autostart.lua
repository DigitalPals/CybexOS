hl.on("hyprland.start", function()
  -- One process serializes environment publication, target activation, and
  -- portal refresh. Separate async execs race target units against a partially
  -- imported environment on a fresh login.
  -- Development mode loads this file verbatim even on an ISO installation,
  -- where the packaged helper lives in /usr/libexec. Resolve the installed
  -- helper at startup instead of relying on the image's path rewriting.
  hl.exec_cmd([[
    starter=/usr/local/libexec/cybexos-hyprland-session-start
    if [ ! -x "$starter" ]; then
      starter=/usr/libexec/cybexos-hyprland-session-start
    fi
    exec "$starter"
  ]])
end)
