-- Detached perspective-safe battle snapshots. Controller views carry only
-- source-visible information: a controller reads its own roster in full and
-- active opponents as public health bars, never opposing moves, items, or
-- sealed peer choices. Debug reads are explicitly trusted and stay a
-- separate entrypoint, never the default controller argument. Every view is
-- copied at snapshot time, so mutating a returned table cannot reach live
-- simulation state and delayed reads stay stable.

local BattleErrors = require("libs.battle.src.errors")

---@class BattleView
local BattleView = {}

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@param handle table<string, unknown> live session or interruption snapshot
---@return table<string, unknown> the plain snapshot under presentation
local function sourceOf(handle)
  assert(type(handle) == "table", "presentation reads require their battle")
  if type(handle.capture) == "function" then
    local snapshot = handle.capture(handle)
    assert(type(snapshot) == "table", "presentation reads require snapshot state")
    return snapshot --[[@as table<string, unknown>]]
  end
  return handle
end

---@param snapshot table<string, unknown>
---@param controller string
---@return table<integer, integer> participant identities owned by the controller
local function participantsOf(snapshot, controller)
  local owned = {}
  for _, id in
    ipairs(snapshot.participantOrder --[[@as integer[] ]])
  do
    local participant = (snapshot.participants --[[@as table<integer, table<string, unknown>>]])[id]
    if participant.controller == controller then
      owned[#owned + 1] = id
    end
  end
  if #owned == 0 then
    error(BattleErrors.input("undeclared observers cannot open a perspective view", {
      controller = controller,
    }))
  end
  return owned
end

---@param handle table<string, unknown> live session or interruption snapshot
---@param controller string
---@return table<string, unknown> detached controller perspective
function BattleView.forController(handle, controller)
  assert(type(controller) == "string", "perspective views require their controller")
  local snapshot = sourceOf(handle --[[@as table<string, unknown>]])
  local owned = participantsOf(snapshot, controller)
  local isOwned = {}
  for _, id in ipairs(owned) do
    isOwned[id] = true
  end
  local combatants = {}
  for _, id in
    ipairs(snapshot.combatantOrder --[[@as integer[] ]])
  do
    local combatant = (snapshot.combatants --[[@as table<integer, table<string, unknown>>]])[id]
    if
      isOwned[
        combatant.participant --[[@as integer]]
      ] == true
    then
      local entry = {
        combatant = id,
        participant = combatant.participant,
        hp = combatant.hp,
        mon = copyValue(combatant.mon),
      }
      if combatant.active ~= nil then
        local active = combatant.active --[[@as table<string, unknown>]]
        entry.active = true
        entry.position = active.position
        entry.activation = active.activation
      else
        entry.active = false
      end
      combatants[#combatants + 1] = entry
    end
  end
  local opponents = {}
  for _, id in
    ipairs(snapshot.positionOrder --[[@as integer[] ]])
  do
    local position = (snapshot.positions --[[@as table<integer, table<string, unknown>>]])[id]
    if position.occupant ~= nil then
      local combatant = (snapshot.combatants --[[@as table<integer, table<string, unknown>>]])[
        position.occupant --[[@as integer]]
      ]
      if
        isOwned[
          combatant.participant --[[@as integer]]
        ] ~= true
      then
        opponents[#opponents + 1] = {
          combatant = position.occupant,
          participant = combatant.participant,
          position = id,
          hp = combatant.hp,
        }
      end
    end
  end
  local slots = {}
  for _, id in
    ipairs(snapshot.positionOrder --[[@as integer[] ]])
  do
    local position = (snapshot.positions --[[@as table<integer, table<string, unknown>>]])[id]
    slots[#slots + 1] = { id = id, side = position.side, occupant = position.occupant }
  end
  local pending = snapshot.pending --[[@as table<string, unknown>]]
  local batch = nil
  if pending ~= nil then
    local record = pending.batch --[[@as table<string, unknown>]]
    batch = { id = record.id, epoch = record.epoch }
  end
  return {
    controller = controller,
    ruleset = snapshot.ruleset,
    format = snapshot.format,
    round = snapshot.round,
    status = snapshot.status,
    combatants = combatants,
    opponents = opponents,
    positions = slots,
    batch = batch,
  }
end

---@param handle table<string, unknown> live session or interruption snapshot
---@return table<string, unknown> detached trusted full read
function BattleView.forDebug(handle)
  local snapshot = sourceOf(handle --[[@as table<string, unknown>]])
  return copyValue(snapshot) --[[@as table<string, unknown>]]
end

return BattleView
