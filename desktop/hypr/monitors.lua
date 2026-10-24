-- Vendor monitor rules. They are recorded as well as applied so that
-- displays.lua (Settings -> Displays) can start a saved choice from the rule
-- it overrides and keep fields the page does not own, such as bitdepth.
local vendor_monitor_rules = {}
_G.__cybexos_vendor_monitor_rules = vendor_monitor_rules
local function monitor(rule)
  table.insert(vendor_monitor_rules, rule)
  hl.monitor(rule)
end


-- Portable default: use each connected output's preferred mode and let
-- Hyprland choose its position and scale.
monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

