-- Deterministic test-visible record of one wild battle handoff: the route
-- under test, the host phase, the source task frame, the envelope cover,
-- the staged scene identity, the staged member identities, the live
-- emitter counts, and the pane/plane draws behind each accepted tick.
-- Tests only; production code never requires this module.

local M = {}
M.__index = M

---@param route string route identity under observation, e.g. "general/grass/day"
---@return table trace recorder behind one handoff
function M.new(route)
  assert(type(route) == "string" and route ~= "", "a handoff trace names its route")
  return setmetatable({ route = route, _rows = {} }, M)
end

---@param row table<string, unknown> one accepted tick under observation
---@field hostPhase string? launch/host phase behind the tick
---@field taskFrame integer? source encounter frame published by the tick, nil before frame 1
---@field cover integer envelope cover coefficient behind the tick, 0..16
---@field scene string? staged scene identity behind the tick
---@field members table? staged member identities behind the tick
---@field activeEmitters integer[]? live emitter counts per system behind the tick
---@field draws table[]? pane/plane draws behind the tick as { pane = "main"|"sub", plane = "bg"|"obj"|"spl" }
function M:observe(row)
  assert(type(row) == "table", "a handoff trace observes tick records")
  local cover = assert(row.cover, "a handoff tick records its cover")
  assert(type(cover) == "number", "a handoff tick records its numeric cover")
  self._rows[#self._rows + 1] = {
    tick = #self._rows + 1,
    hostPhase = row.hostPhase,
    taskFrame = row.taskFrame,
    cover = cover,
    scene = row.scene,
    members = row.members,
    activeEmitters = row.activeEmitters,
    draws = row.draws,
  }
end

---@return table[] observed tick rows in acceptance order
function M:rows()
  return self._rows
end

---@return integer[] cover coefficients in acceptance order
function M:covers()
  local covers = {}
  for _, row in ipairs(self._rows) do
    covers[#covers + 1] = row.cover
  end
  return covers
end

---@return table[] rows publishing a source task frame
function M:framedRows()
  local framed = {}
  for _, row in ipairs(self._rows) do
    if row.taskFrame ~= nil then
      framed[#framed + 1] = row
    end
  end
  return framed
end

---@param row table<string, unknown> one observed tick row
---@return string deterministic single-line rendering of the row
local function renderRow(route, row)
  local members = "none"
  if type(row.members) == "table" then
    members = table.concat(row.members, "+")
  elseif row.members ~= nil then
    members = tostring(row.members)
  end
  local emitters = "none"
  if type(row.activeEmitters) == "table" then
    local counts = {}
    for _, count in ipairs(row.activeEmitters) do
      counts[#counts + 1] = tostring(count)
    end
    emitters = table.concat(counts, "+")
  end
  local draws = "none"
  if type(row.draws) == "table" then
    local planes = {}
    for _, draw in ipairs(row.draws) do
      planes[#planes + 1] = tostring(draw.pane) .. "/" .. tostring(draw.plane)
    end
    draws = table.concat(planes, "+")
  end
  return "tick="
    .. tostring(row.tick)
    .. " route="
    .. route
    .. " host="
    .. tostring(row.hostPhase)
    .. " frame="
    .. tostring(row.taskFrame)
    .. " cover="
    .. tostring(row.cover)
    .. " scene="
    .. tostring(row.scene)
    .. " members="
    .. members
    .. " emitters="
    .. emitters
    .. " draws="
    .. draws
end

---@return string deterministic multiline rendering of every observed tick
function M:render()
  local lines = {}
  for _, row in ipairs(self._rows) do
    lines[#lines + 1] = renderRow(self.route, row)
  end
  return table.concat(lines, "\n")
end

return M
