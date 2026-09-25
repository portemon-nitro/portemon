-- Classifies normalized collision behavior into the semantic choices available
-- to player-input movement. It has no terrain, actor, progression, or host
-- dependencies; FieldPlayer owns all stateful validation and motion timing.

local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local FieldTraversal = {}

---@param destination table<string, unknown>
---@param direction FieldDirection
---@param mode string? "walking" when omitted, or "surfing"
---@return table<string, unknown>
function FieldTraversal.classify(destination, direction, mode)
  assert(type(destination) == "table", "destination permission record required")
  assert(type(direction) == "string", "traversal direction required")
  assert(mode == nil or mode == "walking" or mode == "surfing", "unknown traversal mode " .. tostring(mode))
  local surfing = mode == "surfing"

  local action = MetatileBehavior.fieldAction(destination.behavior)
  if action == "surf" then
    if not surfing then
      return { kind = "field_action", action = action }
    end
    -- Swimming ignores the walking permission block: connected water is
    -- entered through the behavior rule, while the probe path, terrain
    -- resolution, and occupancy still gate every real step.
    return { kind = "step" }
  end
  if action then
    return { kind = "field_action", action = action }
  end

  local ledgeDirection = MetatileBehavior.ledgeDirection(destination.behavior)
  if ledgeDirection then
    if surfing then
      return { kind = "blocked" }
    end
    if ledgeDirection ~= direction then
      return { kind = "blocked" }
    end
    return { kind = "ledge_jump" }
  end

  if destination.blocked then
    return { kind = "blocked" }
  end
  if surfing then
    return { kind = "disembark" }
  end
  return { kind = "step" }
end

return FieldTraversal
