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
  local self = { get_layout = get_layout, rules = {}, rule_signature = "", cascade = 0 }
  function self:retire()
    for _, rule in ipairs(self.rules) do rule:set_enabled(false) end
  end
  function self:arrange(windows)
    local claiming = {}
    -- Claim every member before floating any: floating one group member can
    -- float the rest, which must still be returned to tiling afterwards.
    for _, window in ipairs(windows) do
      local workspace = window.workspace
      if not model.regular(workspace) then
        -- Named/special destinations keep their native floating state. Retain
        -- the origin's ownership for a later return (including minimize), but
        -- never render a Floating-workspace decoration on this destination.
        M.tag(window, M.FLOATING, false)
      else
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
  function self:opened(window)
    local members = window.group and window.group.members or { window }
    -- Native grouping precedes openLate. Origin provenance follows the group
    -- even through named/special destinations; copying tags must not depend on
    -- today's layout, fullscreen or pin state. Arrange alone decides whether
    -- this destination permits floating/tiling or Floating titlebar tags.
    for _, member in ipairs(members) do
      if member ~= window and M.tagged(member, M.USER) then
        M.tag(window, M.FLOATED, false)
        M.tag(window, M.USER, true)
        break
      end
    end
    -- A manual group choice wins over mode ownership. Without either origin
    -- tag on another member, independent native/app floaters stay unclaimed.
    if not M.tagged(window, M.USER) then
      for _, member in ipairs(members) do
        if member ~= window and M.tagged(member, M.FLOATED) then
          M.tag(window, M.FLOATED, true)
          break
        end
      end
    end
    self:arrange(members)
  end
  function self:sync_rules(preferences)
    local data = require("workspace_state")
    -- Saved numbered overrides stay dormant while their ID has a user name.
    -- Include this boundary in the signature so renames/reloads retire the
    -- old numeric native rule without discarding the saved choice.
    local named, suspended = {}, data.array()
    for _, workspace in ipairs(hl.get_workspaces()) do
      local key = tostring(workspace.id)
      if preferences.layouts[key] and not model.regular(workspace) then
        named[key] = true
        suspended[#suspended + 1] = key
      end
    end
    table.sort(suspended); suspended.n = #suspended
    local signature = data.encode({ defaultLayout = preferences.defaultLayout, manageDefaultLayout = preferences.manageDefaultLayout,
      layouts = preferences.layouts, suspended = suspended })
    if signature == self.rule_signature then return end
    self.rule_signature = signature
    for _, rule in ipairs(self.rules) do rule:set_enabled(false) end
    self.rules = {}
    if preferences.manageDefaultLayout ~= false then
      hl.config({ general = { layout = preferences.defaultLayout == "floating" and "dwindle" or preferences.defaultLayout } })
    end
    for id, layout in pairs(preferences.layouts) do
      if not named[id] then
        self.rules[#self.rules + 1] = hl.workspace_rule({ workspace = id,
          layout = layout == "floating" and "dwindle" or layout })
      end
    end
  end
  return self
end
return M
