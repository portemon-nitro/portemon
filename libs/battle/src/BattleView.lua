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

---@param snapshot table<string, unknown> borrowed live state or explicit snapshot record
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

---@param snapshot table<string, unknown> borrowed live state or explicit snapshot record
---@param controller string
---@return table<string, unknown> detached controller perspective
function BattleView.forController(snapshot, controller)
  assert(type(snapshot) == "table", "perspective views require their battle")
  assert(type(controller) == "string", "perspective views require their controller")
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

---@param snapshot table<string, unknown> explicit detached capture under trusted inspection
---@return table<string, unknown> detached trusted full read
function BattleView.forDebug(snapshot)
  assert(type(snapshot) == "table", "trusted reads require their capture")
  return copyValue(snapshot) --[[@as table<string, unknown>]]
end

---@param mon unknown battle-local mon record under condition inspection
---@return string? major condition key on the canonical mon, nil when healthy
local function majorConditionOf(mon)
  if type(mon) ~= "table" then
    return nil
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition --[[@as table<string, unknown>?]]
  if type(condition) ~= "table" then
    return nil
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects --[[@as table<integer, unknown>?]]
  if type(effects) ~= "table" then
    return nil
  end
  local current = (effects --[[@as table<integer, unknown>]])[1] --[[@as table<string, unknown>?]]
  if type(current) ~= "table" or type(current.key) ~= "string" then
    return nil
  end
  return current.key --[[@as string]]
end

-- Reduced semantic checkpoint of the observable battle at one event: the
-- active combatants' stable identity, visible health, major condition,
-- and progression facts. Benched reserves, move stores, inventories,
-- submitted plans, continuation stacks, and randomness never enter the
-- projection, so nested event payloads cannot leak unrevealed state.
-- The projection is pure and deterministic: the same mechanics state
-- always answers the same checkpoint.
---@param handle table<string, unknown> live battle state, session, or snapshot under projection
---@return table<string, unknown> detached event-time checkpoint
function BattleView.checkpoint(handle)
  local snapshot = sourceOf(handle --[[@as table<string, unknown>]])
  local combatants = snapshot.combatants --[[@as table<integer, table<string, unknown>>]]
  local participants = snapshot.participants --[[@as table<integer, table<string, unknown>>]]
  local checkpoint = {
    hp = {},
    combatants = {},
  } --[[@as table<string, unknown>]]
  local hp = checkpoint.hp --[[@as table<integer, integer>]]
  local entries = checkpoint.combatants --[[@as table<integer, table<string, unknown>>]]
  if type(combatants) ~= "table" then
    return checkpoint
  end
  local order = snapshot.combatantOrder --[[@as integer[]?]]
  local ids = {} ---@type integer[]
  if type(order) == "table" then
    for _, id in ipairs(order) do
      ids[#ids + 1] = id --[[@as integer]]
    end
  else
    for id in pairs(combatants) do
      ids[#ids + 1] = id --[[@as integer]]
    end
    table.sort(ids)
  end
  for _, id in ipairs(ids) do
    local combatant = combatants[id]
    if type(combatant) == "table" and combatant.active ~= nil then
      local active = combatant.active --[[@as table<string, unknown>]]
      hp[id] = combatant.hp
      local ceiling = combatant.maxHp
      if type(ceiling) ~= "number" then
        ceiling = combatant.entryHp
      end
      local record = {
        participant = combatant.participant,
        position = active.position,
        activation = active.activation,
        hp = combatant.hp,
        maxHp = ceiling,
        condition = majorConditionOf(combatant.mon),
      } --[[@as table<string, unknown>]]
      local mon = combatant.mon --[[@as table<string, unknown>?]]
      if type(mon) == "table" then
        if type(mon.species) == "string" then
          record.species = mon.species
        end
        if type(mon.form) == "number" then
          record.form = mon.form
        end
        if type(mon.experience) == "number" then
          record.experience = mon.experience
        end
        if type(mon.level) == "number" then
          record.level = mon.level
        end
      end
      if type(participants) == "table" then
        local participant = participants[
          combatant.participant --[[@as integer]]
        ] --[[@as table<string, unknown>?]]
        if type(participant) == "table" then
          record.side = participant.side
          record.controller = participant.controller
        end
      end
      entries[id] = record
    end
  end
  return checkpoint
end

return BattleView
