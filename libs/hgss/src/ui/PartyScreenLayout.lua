-- Party-screen layout: manifest-backed native 256x192 geometry. Slot
-- rectangles are the six staggered source panels; directional neighbors
-- compile from the default dpad boxes (indices 0..5 address slots, 7
-- addresses cancel, 6 is unreachable); hit targets derive from the
-- default touch rects with right 0 encoding the 256 pane edge. Context
-- menus resolve to one generated source-shaped record per entry through
-- the menu class (top-level 2..8, subcontext 2..5) and count; prompt
-- placement rides the generated yes/no anchor. The shared default column
-- order stays available to nonvisual script selection.
-- Pure module: no love, no I/O.

local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

---@class PartyScreenLayout
local PartyScreenLayout = {}

---@class PartyScreenLayoutResolved
---@field frame ScreenTopology.Rectangle
---@field slotRects table<integer, ScreenTopology.Rectangle>
---@field cancelRect ScreenTopology.Rectangle?
---@field neighbors table<integer|string, table<string, integer|string>>
---@field hitTest fun(x: number, y: number): PartyScreenLayout.Hit?
---@field menuLayout fun(kind: "topLevel"|"subcontext", count: integer): table[]
---@field menuHit fun(kind: "topLevel"|"subcontext", count: integer, x: number, y: number): { index: integer }?
---@field promptAnchor { x: integer, y: integer }
---@field compact boolean always true: native geometry never reflows

---@class PartyScreenLayout.Hit
---@field kind "slot"|"action"|"cancel"
---@field slot integer?
---@field action string?

---@param rect ScreenTopology.Rectangle
---@return ScreenTopology.Rectangle
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- The native pane extent. Context geometry arrives entirely through the
-- generated menu records; no synthetic footer targets exist.
local NATIVE_WIDTH = NativeDisplay.WIDTH
local NATIVE_HEIGHT = NativeDisplay.HEIGHT
local PANE_EDGE = 256

---@param manifest table<string, unknown>
---@return table[] six panel records in slot order
local function manifestPanels(manifest)
  local panels = assert(manifest.panels, "the party manifest carries its six panels")
  assert(type(panels) == "table", "the party manifest carries its six panels")
  local out = {}
  for slot0 = 0, 5 do
    local panel = assert(panels[slot0 + 1], "the party manifest carries panel " .. slot0)
    assert(type(panel) == "table", "party panel " .. slot0 .. " is a record")
    local origin = assert(panel.origin, "party panel " .. slot0 .. " carries its origin")
    local size = assert(panel.size, "party panel " .. slot0 .. " carries its size")
    out[slot0 + 1] = {
      x = assert(origin.x, "party panel origin carries x"),
      y = assert(origin.y, "party panel origin carries y"),
      width = assert(size.width, "party panel size carries width"),
      height = assert(size.height, "party panel size carries height"),
    }
  end
  return out
end

---@param index integer zero-based dpad box index
---@return integer|string? the slot, cancel, or nil when unreachable
local function mapBoxIndex(index)
  if index >= 0 and index <= 5 then
    return index
  end
  if index == 7 then
    return "cancel"
  end
  return nil
end

---@param manifest table<string, unknown>
---@param cancellable boolean
---@return table<integer|string, table<string, integer|string>>
local function compileNeighbors(manifest, cancellable)
  local navigation = assert(manifest.navigation, "the party manifest carries navigation")
  assert(type(navigation) == "table", "the party manifest carries navigation")
  local dpad = assert(navigation.dpad, "the party manifest carries dpad navigation")
  assert(type(dpad) == "table", "the party manifest carries dpad navigation")
  local default = assert(dpad.default, "the party manifest carries the default dpad variant")
  assert(type(default) == "table", "the party manifest carries the default dpad variant")
  local neighbors = {}
  for slot0 = 0, 5 do
    local box = assert(default[slot0 + 1], "the default dpad carries box " .. slot0)
    assert(type(box) == "table", "dpad box " .. slot0 .. " is a record")
    local links = {}
    local up = mapBoxIndex(box.up)
    if up ~= nil and (up ~= "cancel" or cancellable) then
      links.up = up
    end
    local down = mapBoxIndex(box.down)
    if down ~= nil and (down ~= "cancel" or cancellable) then
      links.down = down
    end
    local left = mapBoxIndex(box.leftNeighbor)
    if left ~= nil and (left ~= "cancel" or cancellable) then
      links.left = left
    end
    local right = mapBoxIndex(box.rightNeighbor)
    if right ~= nil and (right ~= "cancel" or cancellable) then
      links.right = right
    end
    neighbors[slot0] = links
  end
  if cancellable then
    local cancelBox = assert(default[8], "the default dpad carries the cancel box")
    assert(type(cancelBox) == "table", "the cancel dpad box is a record")
    local back = mapBoxIndex(cancelBox.up)
    local links = { up = back == nil and 5 or back }
    local down = mapBoxIndex(cancelBox.down)
    local left = mapBoxIndex(cancelBox.leftNeighbor)
    local right = mapBoxIndex(cancelBox.rightNeighbor)
    if down ~= nil then
      links.down = down
    end
    if left ~= nil then
      links.left = left
    end
    if right ~= nil then
      links.right = right
    end
    neighbors.cancel = links
  end
  return neighbors
end

---@param record table<string, unknown> a touch rect with right 0 encoding the pane edge
---@return ScreenTopology.Rectangle
local function touchRect(record)
  assert(type(record) == "table", "touch rects arrive as records")
  local right = assert(record.right, "touch rects carry a right edge")
  assert(type(record.top) == "number", "touch rects carry integer edges")
  if right == 0 then
    right = PANE_EDGE
  end
  assert(type(right) == "number", "touch rects carry integer edges")
  return {
    x = assert(record.left, "touch rects carry a left edge"),
    y = record.top,
    width = right - record.left,
    height = assert(record.bottom, "touch rects carry a bottom edge") - record.top,
  }
end

---@param manifest table<string, unknown>
---@return table[] the seven default touch rects: six slots then cancel
local function manifestTouch(manifest)
  local hitboxes = assert(manifest.hitboxes, "the party manifest carries hitboxes")
  assert(type(hitboxes) == "table", "the party manifest carries hitboxes")
  local touch = assert(hitboxes.touch, "the party manifest carries touch hitboxes")
  assert(type(touch) == "table", "the party manifest carries touch hitboxes")
  local default = assert(touch.default, "the party manifest carries the default touch variant")
  assert(type(default) == "table", "the party manifest carries the default touch variant")
  assert(#default == 7, "the default touch variant carries six slots plus cancel")
  return default
end

---@param manifest table<string, unknown>
---@param kind "topLevel"|"subcontext"
---@param count integer
---@return table[] one generated record per menu entry
local function manifestMenuEntries(manifest, kind, count)
  assert(kind == "topLevel" or kind == "subcontext", "party menus stay in the top-level/subcontext set")
  assert(type(count) == "number" and count % 1 == 0, "party menu lookups count their entries, got " .. tostring(count))
  local contextMenu = assert(manifest.contextMenu, "the party manifest carries context menus")
  assert(type(contextMenu) == "table", "the party manifest carries context menus")
  local section = assert(contextMenu[kind], "the party manifest carries the " .. kind .. " menu section")
  assert(type(section) == "table", "the party manifest carries the " .. kind .. " menu section")
  local entries = section[count]
  assert(type(entries) == "table", "unsupported " .. kind .. " menu count " .. tostring(count))
  return entries
end

---@param manifest table<string, unknown>
---@return { x: integer, y: integer } the generated yes/no prompt anchor
local function manifestPromptAnchor(manifest)
  local windows = assert(manifest.windows, "the party manifest carries windows")
  assert(type(windows) == "table", "the party manifest carries windows")
  local prompt = assert(windows.prompt, "the party manifest carries the prompt anchor")
  assert(type(prompt) == "table", "the party manifest carries the prompt anchor")
  return {
    x = assert(prompt.x, "the prompt anchor carries x"),
    y = assert(prompt.y, "the prompt anchor carries y"),
  }
end

---@class PartyScreenLayout.Spec
---@field manifest table<string, unknown> the validated party presentation manifest
---@field cancellable boolean?

---@param spec PartyScreenLayout.Spec
---@return PartyScreenLayoutResolved
function PartyScreenLayout.resolve(spec)
  assert(type(spec) == "table", "party layout requires a specification")
  local manifest = assert(spec.manifest, "native party geometry requires its manifest")
  assert(type(manifest) == "table", "native party geometry requires its manifest")
  local cancellable = spec.cancellable
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "party layout cancel permission must be a boolean")

  local frame = { x = 0, y = 0, width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
  local slotRects = manifestPanels(manifest)
  local neighbors = compileNeighbors(manifest, cancellable)
  local touch = manifestTouch(manifest)
  local cancelRect
  if cancellable then
    cancelRect = touchRect(assert(touch[7], "the default touch variant carries cancel"))
  end
  ---@param x number
  ---@param y number
  ---@return PartyScreenLayout.Hit?
  local function hitTest(x, y)
    assert(type(x) == "number" and type(y) == "number", "hit testing needs coordinates")
    for slot0 = 0, 5 do
      if LayoutGeometry.containsPoint(slotRects[slot0 + 1], x, y) then
        return { kind = "slot", slot = slot0 }
      end
    end
    if cancelRect ~= nil and LayoutGeometry.containsPoint(cancelRect, x, y) then
      return { kind = "cancel" }
    end
    return nil
  end

  ---@param kind "topLevel"|"subcontext"
  ---@param count integer
  ---@return table[] one generated record per menu entry
  local function menuLayout(kind, count)
    return manifestMenuEntries(manifest, kind, count)
  end

  ---@param kind "topLevel"|"subcontext"
  ---@param count integer
  ---@param x number
  ---@param y number
  ---@return { index: integer }?
  local function menuHit(kind, count, x, y)
    assert(type(x) == "number" and type(y) == "number", "menu hit testing needs coordinates")
    local entries = manifestMenuEntries(manifest, kind, count)
    for index, entry in ipairs(entries) do
      local target = assert(entry.touch, "menu entries carry touch targets")
      if LayoutGeometry.containsPoint(touchRect(target), x, y) then
        return { index = index }
      end
    end
    return nil
  end

  return {
    frame = frame,
    slotRects = slotRects,
    cancelRect = cancelRect ~= nil and copyRect(cancelRect) or nil,
    neighbors = neighbors,
    hitTest = hitTest,
    menuLayout = menuLayout,
    menuHit = menuHit,
    promptAnchor = manifestPromptAnchor(manifest),
    compact = true,
  }
end

-- The canonical navigation order shared by compositions without live
-- viewport geometry (script selection): the slot column into cancel.
---@param cancellable boolean?
---@return table<integer|string, table<string, integer|string>>
function PartyScreenLayout.defaultNeighbors(cancellable)
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "cancel permission must be a boolean")
  local neighbors = {}
  for slot0 = 0, 5 do
    local links = {}
    if slot0 > 0 then
      links.up = slot0 - 1
    end
    if slot0 < 5 then
      links.down = slot0 + 1
    elseif cancellable then
      links.down = "cancel"
    end
    neighbors[slot0] = links
  end
  if cancellable then
    neighbors.cancel = { up = 5 }
  end
  return neighbors
end

return PartyScreenLayout
