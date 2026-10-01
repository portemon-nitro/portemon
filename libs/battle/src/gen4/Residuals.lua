-- Native residual continuation: one end-of-turn pass over the ordered
-- residual candidates. Ticks traverse in sampled speed order through the
-- shared finite dispatch; each killing tick is followed at once by its
-- faint without ending the phase early, and a fainted combatant's later
-- instances stay silent while survivors still tick. The pass suspends on
-- an operation budget and restores exactly behind its saved cursor, so
-- budgeted suspension and snapshot restore never repeat completed work.
-- Attribution stored on an instance outlives a departed source because
-- dispatch never rewrites it.

local BattleErrors = require("libs.battle.src.errors")

---@class ResidualSpeeds
---@field speeds table<integer, integer> sampled speed per combatant
---@field health table<integer, integer> battle-local health per combatant
---@field stream table<string, unknown>? labeled battle stream for rolled ticks
---@field suppressedIds table<integer, boolean>? instances muted for this pass
---@field resume ResidualFrame? continuation of a suspended pass

---@class ResidualFrame
---@field kind string
---@field version integer
---@field checkpoint table<string, unknown>? finite-dispatch continuation, absent when the pass finished
---@field fainted integer[] combatants settled before the cursor, in order

---@class ResidualOutcome
---@field events table<string, unknown>[]
---@field done boolean
---@field frame ResidualFrame

---@class ResidualDispatchView
---@field collect fun(self: ResidualDispatchView, timing: string, context: table<string, unknown>): table<integer, table<string, unknown>>
---@field invoke fun(self: ResidualDispatchView, timing: string, context: table<string, unknown>, budget: integer?): table<string, unknown>

local Residuals = {}

Residuals.KIND = "gen4:residuals"
Residuals.VERSION = 1

---@param frame unknown
---@return ResidualFrame
function Residuals.validateFrame(frame)
  if type(frame) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("residual frames are records", {}))
  end
  assert(type(frame) == "table", "residual frame validated above")
  if frame.kind ~= Residuals.KIND then
    error(BattleErrors.incompatibleSnapshot("residual frames carry the native residual identity", {}))
  end
  if frame.version ~= Residuals.VERSION then
    error(BattleErrors.incompatibleSnapshot("residual frames carry the current version", {}))
  end
  if frame.checkpoint ~= nil and type(frame.checkpoint) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("residual frames carry a dispatch continuation or none", {}))
  end
  if type(frame.fainted) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("residual frames carry their settled combatants", {}))
  end
  for index, combatant in ipairs(frame.fainted) do
    if type(combatant) ~= "number" then
      error(BattleErrors.incompatibleSnapshot("residual frames settle combatant identities", { index = index }))
    end
  end
  return frame --[[@as ResidualFrame]]
end

---@param health table<integer, integer>
---@param fainted table<integer, boolean>
---@param ordered integer[] settled combatants in first-seen order
---@param combatant integer newly settled combatant identity
local function markFainted(health, fainted, ordered, combatant)
  if fainted[combatant] == nil then
    fainted[combatant] = true
    ordered[#ordered + 1] = combatant
    health[combatant] = 0
  end
end

---@param context ResidualSpeeds
---@return table<integer, integer> battle-local health under the pass
local function checkHealth(context)
  if type(context.health) ~= "table" then
    error(BattleErrors.invalidState("residual passes read battle-local health", {}))
  end
  return context.health --[[@as table<integer, integer>]]
end

--- Runs the residual pass to completion or to its operation budget, where
--- one unit is one invoked instance. Faint events interleave immediately
--- after their killing tick; restoring mid-pass resumes behind the saved
--- cursor with completed ticks never running twice.
---@param dispatch ResidualDispatchView finite dispatch owning residual collection and liveness
---@param context ResidualSpeeds pass context; resume continues a suspended pass
---@param budget integer? invoked instances this call may spend before yielding
---@return ResidualOutcome pass events with its completion flag and frame
function Residuals.step(dispatch, context, budget)
  assert(type(dispatch) == "table", "residual passes run through the finite dispatch")
  assert(
    type(dispatch.collect) == "function" and type(dispatch.invoke) == "function",
    "residual passes collect and invoke one timing"
  )
  assert(type(context) == "table", "residual passes carry their pass context")
  local health = checkHealth(context)
  local allowance = budget
  if allowance ~= nil then
    assert(
      type(allowance) == "number" and allowance % 1 == 0 and allowance >= 1,
      "residual passes spend a positive operation budget"
    )
  end
  local checkpoint = nil
  local fainted = {}
  local ordered = {}
  if context.resume ~= nil then
    local frame = Residuals.validateFrame(context.resume)
    checkpoint = frame.checkpoint
    for _, combatant in ipairs(frame.fainted) do
      markFainted(health, fainted, ordered, combatant)
    end
  end
  for combatant, hp in pairs(health) do
    if type(combatant) == "number" and type(hp) == "number" and hp <= 0 then
      markFainted(health, fainted, ordered, combatant)
    end
  end
  local suppressed = {}
  for _, entry in ipairs(dispatch:collect("residual", context)) do
    local instance = entry.instance
    if
      type(instance) == "table"
      and type(instance.scope) == "table"
      and type(instance.scope.combatant) == "number"
      and fainted[instance.scope.combatant] == true
    then
      suppressed[instance.id] = true
    end
  end
  local events = {}
  local done = false
  while (allowance == nil or allowance >= 1) and not done do
    local inner = {
      speeds = context.speeds,
      health = context.health,
      stream = context.stream,
      suppressedIds = suppressed,
      resume = checkpoint,
    }
    local outcome = dispatch:invoke("residual", inner, 1)
    if type(outcome) ~= "table" or type(outcome.events) ~= "table" then
      error(BattleErrors.invalidState("residual passes consume dispatch outcomes", {}))
    end
    for _, event in ipairs(outcome.events) do
      events[#events + 1] = event
    end
    checkpoint = outcome.checkpoint
    done = outcome.done == true
    local order = {} ---@type integer[]
    for combatant in pairs(health) do
      assert(type(combatant) == "number" and combatant % 1 == 0, "residual health is keyed by combatant identity")
      order[#order + 1] = combatant
    end
    local speeds = context.speeds
    table.sort(order, function(left, right)
      local leftSpeed = 0
      local rightSpeed = 0
      if type(speeds) == "table" then
        if type(speeds[left]) == "number" then
          leftSpeed = speeds[left]
        end
        if type(speeds[right]) == "number" then
          rightSpeed = speeds[right]
        end
      end
      if leftSpeed ~= rightSpeed then
        return leftSpeed > rightSpeed
      end
      return left < right
    end)
    for _, combatant in ipairs(order) do
      local hp = health[combatant]
      if type(hp) == "number" and hp <= 0 and fainted[combatant] == nil then
        markFainted(health, fainted, ordered, combatant)
        events[#events + 1] = { kind = "faint", combatant = combatant }
        for _, entry in ipairs(dispatch:collect("residual", context)) do
          local instance = entry.instance
          if
            type(instance) == "table"
            and type(instance.scope) == "table"
            and instance.scope.combatant == combatant
          then
            suppressed[instance.id] = true
          end
        end
      end
    end
    if allowance ~= nil then
      allowance = allowance - 1
    end
  end
  return {
    events = events,
    done = done,
    frame = { kind = Residuals.KIND, version = Residuals.VERSION, checkpoint = checkpoint, fainted = ordered },
  }
end

return Residuals
