-- Floating ownership/placement adapted from Omarchy v4.5.0-rc1 workspace-modes.
-- Copyright (c) David Heinemeier Hansson. MIT permission and warranty notice:
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions: The above copyright notice and this
-- permission notice shall be included in all copies or substantial portions of
-- the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
-- EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
-- OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
-- ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.
local model = require("workspace_model")
local M = { FLOATED = "cybexos-mode-floated", OPENED = "cybexos-mode-opened",
  FLOATING = "cybexos-floating-workspace", USER = "cybexos-user-float" }
function M.tagged(window, tag)
  for _, value in ipairs(window.tags or {}) do
    if value == tag or value == tag .. "*" then return true end
  end
  return false
end
function M.tag(window, tag, on)
  if M.tagged(window, tag) ~= on then
    hl.dispatch(hl.dsp.window.tag({ tag = (on and "+" or "-") .. tag, window = window }))
  end
end
function M.bounds(monitor)
  if not monitor then return nil end
  local scale = tonumber(monitor.scale) or 1
  if scale <= 0 then scale = 1 end
  local width, height = (monitor.width or 1920) / scale, (monitor.height or 1080) / scale
  if (monitor.transform or 0) % 2 == 1 then width, height = height, width end
  local reserved = monitor.reserved or {}
  local x, y = (monitor.x or (monitor.position or {}).x or 0) + (reserved.left or 0),
    (monitor.y or (monitor.position or {}).y or 0) + (reserved.top or 0)
  return { x = x, y = y, width = math.max(1, width - (reserved.left or 0) - (reserved.right or 0)),
    height = math.max(1, height - (reserved.top or 0) - (reserved.bottom or 0)) }
end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
function M.geometry(window)
  local bounds = M.bounds(window.monitor)
  if not bounds then return nil end
  local at, size = window.at or {}, window.size or {}
  return { x = clamp(((at.x or bounds.x) - bounds.x) / bounds.width, 0, 1),
    y = clamp(((at.y or bounds.y) - bounds.y) / bounds.height, 0, 1),
    width = clamp((size.x or bounds.width * 0.64) / bounds.width, 0.05, 1),
    height = clamp((size.y or bounds.height * 0.68) / bounds.height, 0.05, 1) }
end
function M.place(window, saved, cascade)
  local bounds = M.bounds(window.monitor)
  if not bounds then return end
  local width = math.floor(clamp(saved and saved.width * bounds.width or math.min(1100, bounds.width * 0.64), 1, bounds.width))
  local height = math.floor(clamp(saved and saved.height * bounds.height or math.min(760, bounds.height * 0.68), 1, bounds.height))
  local step = ((cascade or 2) % 5 - 2) * 24
  local x = saved and bounds.x + saved.x * bounds.width or bounds.x + (bounds.width - width) / 2 + step
  local y = saved and bounds.y + saved.y * bounds.height or bounds.y + (bounds.height - height) / 2 + step
  x, y = math.floor(clamp(x, bounds.x, bounds.x + bounds.width - width)),
    math.floor(clamp(y, bounds.y, bounds.y + bounds.height - height))
  hl.dispatch(hl.dsp.window.resize({ x = width, y = height, relative = false, window = window }))
  hl.dispatch(hl.dsp.window.move({ x = x, y = y, relative = false, window = window }))
end
function M.new(get_layout)
  local self = { get_layout = get_layout, rules = {}, open_rules = {}, rule_signature = "", cascade = 0 }
  function self:retire()
    for _, rule in ipairs(self.rules) do rule:set_enabled(false) end
    for _, rule in ipairs(self.open_rules) do rule:set_enabled(false) end
  end
  function self:arrange(windows)
    local claiming = {}
    -- Claim every member before floating any: floating one group member can
    -- float the rest, which must still be returned to tiling afterwards.
    for _, window in ipairs(windows) do
      local workspace = window.workspace
      if model.regular(workspace) then
        local floating = self.get_layout(workspace.id) == "floating"
        M.tag(window, M.FLOATING, floating)
        if floating then
          if not M.tagged(window, M.USER) and (M.tagged(window, M.OPENED) or not window.floating) then
            if (window.fullscreen or 0) == 0 and not window.pinned then
              M.tag(window, M.FLOATED, true)
              claiming[#claiming + 1] = window
            end
          end
        else
          M.tag(window, M.USER, false)
          if M.tagged(window, M.FLOATED) and not window.pinned and (window.fullscreen or 0) == 0 then
            M.tag(window, M.FLOATED, false)
            if window.floating then hl.dispatch(hl.dsp.window.float({ action = "off", window = window })) end
          end
        end
      end
    end
    for _, window in ipairs(claiming) do
      if not window.floating then
        hl.dispatch(hl.dsp.window.float({ action = "on", window = window }))
        self.cascade = (self.cascade + 1) % 5
        M.place(window, nil, self.cascade)
      end
    end
  end
  function self:sync_rules(preferences)
    local data = require("workspace_state")
    -- The config collector owns ordinary Lua arrays. Encode private copies as
    -- JSON arrays without adding our .n marker to those shared input tables.
    local exclusions = {}
    for key, patterns in pairs(_G.__cybexos_float_exclusions or {}) do
      local copy = {}
      for i, pattern in ipairs(patterns) do copy[i] = pattern end
      exclusions[key] = data.array(copy)
    end
    local signature = data.encode({ defaultLayout = preferences.defaultLayout, manageDefaultLayout = preferences.manageDefaultLayout,
      layouts = preferences.layouts,
      exclusions = exclusions })
    if signature == self.rule_signature then return end
    self.rule_signature = signature
    for _, rule in ipairs(self.rules) do rule:set_enabled(false) end
    for _, rule in ipairs(self.open_rules) do rule:set_enabled(false) end
    self.rules, self.open_rules = {}, {}
    if preferences.manageDefaultLayout ~= false then
      hl.config({ general = { layout = preferences.defaultLayout == "floating" and "dwindle" or preferences.defaultLayout } })
    end
    local exceptions = {}
    for id, layout in pairs(preferences.layouts) do
      exceptions[#exceptions + 1] = tonumber(id)
      self.rules[#self.rules + 1] = hl.workspace_rule({ workspace = id,
        layout = layout == "floating" and "dwindle" or layout })
    end
    table.sort(exceptions)
    local ranges, start = {}, 1
    if preferences.manageDefaultLayout ~= false and preferences.defaultLayout == "floating" then
      for _, id in ipairs(exceptions) do
        if preferences.layouts[tostring(id)] ~= "floating" then
          if start < id then ranges[#ranges + 1] = { start, id - 1 } end
          start = id + 1
        end
      end
      ranges[#ranges + 1] = { start, model.MAX_ID }
    else
      for _, id in ipairs(exceptions) do
        if preferences.layouts[tostring(id)] == "floating" then ranges[#ranges + 1] = { id, id } end
      end
    end
    for i, range in ipairs(ranges) do
      if range[1] <= range[2] then
        local match = { workspace = string.format("r[%d-%d]", range[1], range[2]), modal = false }
        for key, patterns in pairs(exclusions) do
          if #patterns > 0 then match[key] = "negative:" .. table.concat(patterns, "|") end
        end
        self.open_rules[#self.open_rules + 1] = hl.window_rule({ name = "cybexos-floating-open-" .. i,
          match = match, float = true, tag = "+" .. M.OPENED,
          size = "min(1100,monitor_w*0.64) min(760,monitor_h*0.68)",
          move = "(monitor_w-min(1100,monitor_w*0.64))/2 (monitor_h-min(760,monitor_h*0.68))/2" })
      end
    end
  end
  return self
end
return M
