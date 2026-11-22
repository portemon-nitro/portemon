-- Source focus navigation for the PC Storage box screen.
-- The node graph, forced links and return-column memory follow the retail
-- grid input handler: direction bytes with the high bit set remember the node
-- the player came from so a wrapped move returns to the same column.

local Layouts = require("libs.hgss.src.ui.PcStorageGridData")

---@class PcStorageGrid
---@field _name string
---@field _node integer
---@field _rowCursor integer
---@field _returnInput integer?
---@field _enabled table<integer, boolean>
local PcStorageGrid = {}
PcStorageGrid.__index = PcStorageGrid

local DIRECTIONS = {
  up = { field = "up", opposite = "down" },
  down = { field = "down", opposite = "up" },
  left = { field = "left", opposite = "right" },
  right = { field = "right", opposite = "left" },
}

-- Node kinds whose anchor is a grid cell: the source picks the pointing hand
-- animation there and the open hand over titles, rows and buttons.
local CELL_KINDS = {
  box = true,
  party = true,
  box_tray = true,
  wallpaper = true,
  mark = true,
}

-- Browser layouts by retail mode and party-panel state.
local BROWSE_LAYOUTS = {
  [0] = { closed = "deposit", open = "deposit" },
  [1] = { closed = "withdraw", open = "withdraw" },
  [2] = { closed = "move", open = "moveParty" },
  [3] = { closed = "item", open = "itemParty" },
}

---@param name string
---@return table[]
function PcStorageGrid.layout(name)
  return assert(Layouts[name], "Storage grid layout is known: " .. tostring(name))
end

---@param mode integer
---@param partyOpen boolean
---@return string
function PcStorageGrid.browseLayout(mode, partyOpen)
  local entry = assert(BROWSE_LAYOUTS[mode], "Storage mode has a grid layout")
  return partyOpen and entry.open or entry.closed
end

-- Storage grid node ids are zero-based source ids; the data arrays are
-- one-based Lua sequences.
---@param name string
---@param index integer
---@return table
function PcStorageGrid.node(name, index)
  assert(type(index) == "number" and index >= 0 and index % 1 == 0, "Storage grid node id is a source index")
  return assert(PcStorageGrid.layout(name)[index + 1], "Storage grid node exists: " .. name .. ":" .. index)
end

-- Highest node of the layout, used by tests and bounds assertions.
---@param name string
---@return integer
function PcStorageGrid.nodeCount(name)
  return #PcStorageGrid.layout(name) - 1
end

---@param layoutName string
---@param index integer
---@return PcStorageGrid
function PcStorageGrid.new(layoutName, index)
  PcStorageGrid.node(layoutName, index)
  return setmetatable({
    _name = layoutName,
    _node = index,
    _rowCursor = index,
    _returnInput = nil,
    _enabled = {},
  }, PcStorageGrid)
end

---@return string
function PcStorageGrid:layoutName()
  return self._name
end

---@return integer
function PcStorageGrid:index()
  return self._node
end

---@return table
function PcStorageGrid:current()
  return PcStorageGrid.node(self._name, self._node)
end

---@return string
function PcStorageGrid:kind()
  return self:current().kind
end

---@return string
function PcStorageGrid:pose()
  return CELL_KINDS[self:current().kind] and "menu" or "browse"
end

---@param index integer
function PcStorageGrid:setRowCursor(index)
  PcStorageGrid.node(self._name, index)
  self._rowCursor = index
end

---@param index integer
function PcStorageGrid:setNode(index)
  PcStorageGrid.node(self._name, index)
  self._node = index
  self._returnInput = nil
end

-- Switches to another layout at a node and resets the remembered return
-- column to the initial node, matching a freshly created source grid.
---@param layoutName string
---@param index integer
function PcStorageGrid:setLayout(layoutName, index)
  PcStorageGrid.node(layoutName, index)
  self._name = layoutName
  self._node = index
  self._rowCursor = index
  self._returnInput = nil
  self._enabled = {}
end

---@param index integer
---@param enabled boolean
function PcStorageGrid:setEnabled(index, enabled)
  PcStorageGrid.node(self._name, index)
  self._enabled[index] = enabled == true
end

-- Disables every node outside the given set; used while a panel only offers
-- some of its controls.
---@param indices table<integer, boolean>
function PcStorageGrid:setEnabledOnly(indices)
  for index = 0, PcStorageGrid.nodeCount(self._name) do
    self._enabled[index] = indices[index] == true
  end
end

---@param index integer
---@return boolean
function PcStorageGrid:_isEnabled(index)
  return self._enabled[index] ~= false
end

-- Whether the target node forces the return column: the source marks the
-- link pointing back with the high bit.
---@param index integer
---@param direction string
---@return boolean
function PcStorageGrid:_isForced(index, direction)
  local opposite = assert(DIRECTIONS[direction]).opposite
  local value = assert(PcStorageGrid.node(self._name, index)[opposite], "Storage grid node carries every direction")
  return value >= 0x80
end

-- Follows one direction through the source graph. Returns the landed node, or
-- nil when the graph stays on the current node.
---@param direction "up"|"down"|"left"|"right"
---@return integer?
function PcStorageGrid:move(direction)
  local spec = assert(DIRECTIONS[direction], "Storage grid direction is known")
  local input =
    assert(PcStorageGrid.node(self._name, self._node)[spec.field], "Storage grid node carries every direction")
  ---@cast input integer
  if input >= 0x80 then
    if self._returnInput ~= nil then
      input = assert(self._returnInput)
    else
      input = input - 0x80
    end
  end
  assert(PcStorageGrid.node(self._name, input), "Storage grid link names a node")
  local neighborWasEnabled = true
  local guard = 0
  while not self:_isEnabled(input) do
    neighborWasEnabled = false
    local neighbor =
      assert(PcStorageGrid.node(self._name, input)[spec.field], "Storage grid node carries every direction")
    ---@cast neighbor integer
    neighbor = neighbor % 0x80
    if neighbor == input or neighbor == self._node then
      input = self._node
      break
    end
    input = neighbor
    guard = guard + 1
    assert(guard < 64, "Storage grid disabled-node walk terminates")
  end
  if input == self._node then
    return nil
  end
  local previous = self._node
  if self:_isForced(input, direction) and neighborWasEnabled then
    self._returnInput = previous
  else
    self._returnInput = nil
  end
  self._node = input
  self:_applyReturnColumn(previous)
  return self._node
end

-- Source callbacks remember the last cell of a row and restore it when a
-- wrapped move lands on the first cell of a tray, page or menu.
---@param previous integer
function PcStorageGrid:_applyReturnColumn(previous)
  local name = self._name
  local node = self._node
  if name == "tray" then
    local fromBoxRow = (previous >= 0 and previous <= 5) or (previous >= 24 and previous <= 29)
    if node == 37 and (fromBoxRow or (previous >= 30 and previous <= 31) or previous == 36) then
      self._node = self._rowCursor
      self._returnInput = previous
    end
    if self._node >= 37 and self._node <= 42 then
      self._rowCursor = self._node
    end
  elseif name == "wallpaper" then
    if previous == 6 and node == 0 then
      self._node = self._rowCursor
      self._returnInput = 6
    end
    if self._node >= 0 and self._node <= 3 then
      self._rowCursor = self._node
    end
  elseif name == "boxMenu" or name == "depositBox" then
    if previous == 8 and node == 0 then
      self._node = self._rowCursor
      self._returnInput = 8
    end
    if self._node >= 0 and self._node <= 5 then
      self._rowCursor = self._node
    end
  end
end

-- Finds the node whose source touch rect contains a screen point.
---@param name string
---@param x number
---@param y number
---@return integer?
function PcStorageGrid.hitTest(name, x, y)
  for index, node in ipairs(PcStorageGrid.layout(name)) do
    local hit = node.hit
    if hit ~= nil and x >= hit.x and x < hit.x + hit.width and y >= hit.y and y < hit.y + hit.height then
      return index - 1
    end
  end
  return nil
end

return PcStorageGrid
