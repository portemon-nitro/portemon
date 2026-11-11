-- Replays one typed battle composition frame through a recording
-- graphics boundary: 2D plane content in role order, then OBJ fragments
-- in submission order. Headless suites stub the picture pass with this
-- helper so content assertions observe the same draws production
-- composes, without owning GPU targets.

local CompositionFrameDrain = {}

local PLANE_ROLES = { "menu", "world3d", "window", "transition", "battlefield" }

---@param graphics table<string, unknown> recording graphics boundary
---@param frame table<string, unknown> typed composition frame under replay
function CompositionFrameDrain.drain(graphics, frame)
  assert(type(frame) == "table", "composition drain replays its frame")
  local planes = frame.planes or {}
  for _, role in ipairs(PLANE_ROLES) do
    local entry = planes[role]
    if type(entry) == "table" and type(entry.draw) == "function" then
      entry.draw(graphics)
    end
  end
  for _, fragment in ipairs(frame.objects or {}) do
    assert(type(fragment) == "table" and type(fragment.draw) == "function", "OBJ fragments draw their own coverage")
    fragment.draw(graphics)
  end
end

return CompositionFrameDrain
