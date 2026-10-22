-- Private source-flow selection behind the ordered cue player. The cue
-- player keeps the clock, queue, and displayed facts; this owner only
-- selects which native branch an opening, action occurrence, capture,
-- substitution, or terminal result belongs to and in which order its
-- typed cues run. It never interprets raw battle script opcodes and
-- never recomputes mechanics, damage, catch probability, or rewards.
-- Native branches follow src/battle/battle_controller_player.c
-- (GET_BATTLE_MON, START_ENCOUNTER, TRAINER_MESSAGE, SEND_OUT), the
-- opponent-controller entry tasks in
-- asm/overlay_12_battle_controller_opponent.s, and the ordered waits in
-- src/battle/battle_command.c (BtlCmd_HealthbarSlideIn, BtlCmd_Wait,
-- BtlCmd_PlayMoveAnimation).

local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleMusicSelection = require("game.hgss.src.battle.BattleMusicSelection")

---@class BattlePresentationFlow
local BattlePresentationFlow = {}

-- Canonical semantic slot names behind the native side types 0..5.
-- The names and side types are runtime presentation vocabulary; no
-- source archive index leaks through this mapping.
local SLOT_BY_SIDE_TYPE = {
  [0] = "solo-player",
  [1] = "solo-enemy",
  [2] = "player-side-slot-1",
  [3] = "enemy-side-slot-1",
  [4] = "player-side-slot-2",
  [5] = "enemy-side-slot-2",
}

---@param view table<string, unknown> detached opening dynamic view
---@return boolean wild true while the foe answers the wild controller
function BattlePresentationFlow.isWild(view)
  local foes = view.foes --[[@as table<integer, table<string, unknown>>?]]
  if type(foes) == "table" then
    local first = foes[1] --[[@as table<string, unknown>?]]
    if type(first) == "table" and first.controller == "wild" then
      return true
    end
    if type(first) == "table" and type(first.controller) == "string" then
      return false
    end
  end
  return true
end

---@param view table<string, unknown> detached opening dynamic view
---@return table<string, unknown>? first active own record, nil when no lead is active
function BattlePresentationFlow.activeLead(view)
  local own = view.own --[[@as table<integer, table<string, unknown>>?]]
  if type(own) ~= "table" then
    return nil
  end
  for _, record in ipairs(own) do
    if type(record) == "table" and record.active ~= false then
      return record --[[@as table<string, unknown>]]
    end
  end
  return nil
end

---@param view table<string, unknown> detached dynamic view
---@return table<string, unknown>? first listed foe record, nil when absent
function BattlePresentationFlow.firstFoe(view)
  local foes = view.foes --[[@as table<integer, table<string, unknown>>?]]
  if type(foes) == "table" then
    local first = foes[1] --[[@as table<string, unknown>?]]
    if type(first) == "table" then
      return first
    end
  end
  return nil
end

---@param packet table<string, unknown> detached delivery packet
---@return boolean opening true for the empty first delivery that carries only its views
function BattlePresentationFlow.isOpeningPacket(packet)
  if packet.result ~= nil then
    return false
  end
  local events = packet.events --[[@as table<integer, table<string, unknown>>?]]
  if type(events) == "table" and #events > 0 then
    return false
  end
  return type(packet.before) == "table" or type(packet.after) == "table"
end

---@param attacker integer? striking combatant under narration lookup
---@param move string executed move identity under narration lookup
---@return string occurrence key joining one attack narration across its hits
function BattlePresentationFlow.attackKey(attacker, move)
  local owner = attacker ~= nil and tostring(attacker) or "unknown"
  return owner .. "\0" .. move
end

---@param event table<string, unknown> sanitized kernel event carrying its explicit facts
---@return integer? combatant identity of the capture target, nil when unnamed
function BattlePresentationFlow.captureTarget(event)
  local targets = event.targets --[[@as table<integer, table<string, unknown>>?]]
  if type(targets) == "table" then
    local first = targets[1] --[[@as table<string, unknown>?]]
    if type(first) == "table" and type(first.combatant) == "number" then
      return first.combatant --[[@as integer]]
    end
  end
  local payload = event.payload --[[@as table<string, unknown>?]]
  if type(payload) == "table" and type(payload.target) == "number" then
    return payload.target --[[@as integer]]
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its faint facts
---@return integer? combatant identity of the departing battler, nil when unnamed
function BattlePresentationFlow.faintTarget(event)
  local payload = event.payload --[[@as table<string, unknown>?]]
  if type(payload) == "table" then
    if type(payload.combatant) == "number" then
      return payload.combatant --[[@as integer]]
    end
    if type(payload.target) == "number" then
      return payload.target --[[@as integer]]
    end
  end
  return nil
end

---@param event table<string, unknown> sanitized kernel event carrying its transform facts
---@return integer? combatant identity of the appearance donor, nil when unnamed
function BattlePresentationFlow.transformDonor(event)
  local payload = event.payload --[[@as table<string, unknown>?]]
  if type(payload) == "table" and type(payload.copiedFrom) == "number" then
    return payload.copiedFrom --[[@as integer]]
  end
  return nil
end

---@param word string terminal result word carried by the committed receipt
---@param foeName string? visible foe name for terminal wording
---@return string native result narration for the committed word
function BattlePresentationFlow.resultText(word, foeName)
  if word == "win" then
    if type(foeName) == "string" and foeName ~= "" then
      return "Defeated the foe " .. foeName .. "!"
    end
    return "The foe was defeated!"
  elseif word == "loss" then
    return "Your party can no longer battle!"
  elseif word == "flee" then
    return "Got away safely!"
  elseif word == "capture" then
    if type(foeName) == "string" and foeName ~= "" then
      return "Gotcha! " .. foeName .. " was caught!"
    end
    return "Gotcha! The catch succeeded!"
  elseif word == "draw" then
    return "The battle ended in a draw."
  end
  return "The battle ended."
end

---@param word string terminal result word carried by the committed receipt
---@param wild boolean true while the victory answers a wild encounter
---@return string? staged victory BGM symbol for wins, nil when the word carries no music
function BattlePresentationFlow.resultMusicSymbol(word, wild)
  if word ~= "win" then
    return nil
  end
  -- Native victory is a plain BGM swap (PlayBGM SEQ_GS_WIN2 for wild wins).
  -- Direct timeline drivers carry no trainer class, so trainer wins keep
  -- the kind-level default here; the field leg refines by class.
  return BattleMusicSelection.victoryMusicSymbol(wild and "wild" or "trainer", nil)
end

---@param list table<integer, table<string, unknown>>? detached active records from one side
---@param seen table<integer, boolean> claimed positions already collected
---@param order integer[] sorted distinct positions under collection
local function collectSidePositions(list, seen, order)
  if type(list) ~= "table" then
    return
  end
  for _, record in ipairs(list) do
    if type(record) == "table" and type(record.position) == "number" then
      local position = record.position --[[@as integer]]
      if not seen[position] then
        seen[position] = true
        order[#order + 1] = position
      end
    end
  end
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param side integer battler side under ordering (1 ally, 2 foe)
---@return integer[] sorted distinct occupied positions for the side
local function sidePositionOrder(packet, side)
  local seen = {} ---@type table<integer, boolean>
  local order = {} ---@type integer[]
  local before = packet.before --[[@as table<string, unknown>?]]
  local after = packet.after --[[@as table<string, unknown>?]]
  if type(before) == "table" then
    if side == 1 then
      collectSidePositions(before.own --[[@as table<integer, table<string, unknown>>?]], seen, order)
    else
      collectSidePositions(before.foes --[[@as table<integer, table<string, unknown>>?]], seen, order)
    end
  end
  if type(after) == "table" then
    if side == 1 then
      collectSidePositions(after.own --[[@as table<integer, table<string, unknown>>?]], seen, order)
    else
      collectSidePositions(after.foes --[[@as table<integer, table<string, unknown>>?]], seen, order)
    end
  end
  table.sort(order)
  return order
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param combatant integer combatant identity under lookup
---@param activation unknown activation identity under lookup
---@return table<string, unknown>? exact event-time record, when one side still pictures it
---@return boolean stale true when the combatant survives under a different activation
local function findEventRecord(packet, combatant, activation)
  local stale = false
  local found = nil ---@type table<string, unknown>?
  local function scan(view)
    if type(view) ~= "table" then
      return
    end
    for _, group in ipairs({ view.own, view.foes }) do
      if type(group) == "table" then
        for _, record in ipairs(group) do
          if type(record) == "table" and record.combatant == combatant then
            if record.activation == activation then
              if found == nil then
                found = record --[[@as table<string, unknown>]]
              end
            else
              stale = true
            end
          end
        end
      end
    end
  end
  scan(packet.before --[[@as table<string, unknown>?]])
  scan(packet.after --[[@as table<string, unknown>?]])
  return found, stale
end

---@param packet table<string, unknown> detached delivery packet picturing the event battlers
---@param entry table<string, unknown> sanitized actor/target identity under resolution
---@param role string actor or target role under diagnosis
---@param slotGeometry table<integer, table<string, number>> published native slot rows
---@return table<string, unknown> frozen semantic slot behind the event-time record
local function resolveEntry(packet, entry, role, slotGeometry)
  assert(type(entry.combatant) == "number", role .. " names its combatant")
  assert(entry.activation ~= nil, role .. " names its activation")
  local combatant = entry.combatant --[[@as integer]]
  local record, stale = findEventRecord(packet, combatant, entry.activation)
  if record == nil then
    if stale then
      error(
        role .. " combatant " .. tostring(combatant) .. " no longer carries activation " .. tostring(entry.activation),
        0
      )
    end
    error(
      role
        .. " combatant "
        .. tostring(combatant)
        .. " has no event-time slot for activation "
        .. tostring(entry.activation),
      0
    )
  end
  local side = record.side
  if side ~= 1 and side ~= 2 then
    error(role .. " combatant " .. tostring(combatant) .. " carries no battle side", 0)
  end
  local position = record.position
  if type(position) ~= "number" then
    if type(entry.position) == "number" then
      position = entry.position
    else
      error(role .. " combatant " .. tostring(combatant) .. " carries no battle position", 0)
    end
  end
  local order = sidePositionOrder(packet, side --[[@as integer]])
  if #order == 0 then
    error(role .. " combatant " .. tostring(combatant) .. " has no live side positions", 0)
  end
  if #order > 2 then
    error(role .. " combatant " .. tostring(combatant) .. " has too many live side positions", 0)
  end
  local battler = { side = side, position = position }
  local row
  if #order == 1 then
    row = BattleScene.slotRow(battler, nil, slotGeometry)
  else
    local claimed = false
    for _, slot in ipairs(order) do
      if slot == position then
        claimed = true
        break
      end
    end
    if not claimed then
      error(
        role
          .. " combatant "
          .. tostring(combatant)
          .. " position "
          .. tostring(position)
          .. " is outside its live side order",
        0
      )
    end
    row = BattleScene.slotRow(battler, order, slotGeometry)
  end
  assert(type(row) == "table", role .. " resolves its native slot row")
  local sideType = row.sideType
  assert(type(sideType) == "number", role .. " resolves its native side type")
  local slot = SLOT_BY_SIDE_TYPE[
    sideType --[[@as integer]]
  ]
  if slot == nil then
    error(role .. " combatant " .. tostring(combatant) .. " resolves an unknown side type", 0)
  end
  if side == 1 and sideType ~= 0 and sideType ~= 2 and sideType ~= 4 then
    error(role .. " combatant " .. tostring(combatant) .. " resolves a foe side type", 0)
  end
  if side == 2 and sideType ~= 1 and sideType ~= 3 and sideType ~= 5 then
    error(role .. " combatant " .. tostring(combatant) .. " resolves an ally side type", 0)
  end
  return {
    combatant = combatant,
    activation = entry.activation,
    slot = slot,
    sideType = sideType,
  }
end

-- Adapts one sanitized event into a frozen visual occurrence packet.
-- The attacker and every target resolve against the event-time
-- before/after views only; later roster edits cannot retarget the
-- admitted occurrence. Singles take the solo rows by side size, doubles
-- take their sorted double rows through the shared slot geometry.
---@param packet table<string, unknown> detached delivery packet carrying launch identity and event-time views
---@param event table<string, unknown> sanitized event carrying actor/target and effect facts
---@param slotGeometry table<integer, table<string, number>> published native slot rows
---@return table<string, unknown> detached occurrence packet with frozen semantic slots
function BattlePresentationFlow.animationPlayback(packet, event, slotGeometry)
  assert(type(packet) == "table", "visual topology reads its delivery packet")
  assert(type(event) == "table", "visual topology reads its sanitized event")
  assert(type(slotGeometry) == "table", "visual topology reads its slot geometry")
  local launchId = packet.launchId
  assert(type(launchId) == "string" and launchId ~= "", "visual topology carries its launch identity")
  local packetId = packet.packetId
  assert(
    type(packetId) == "number" and packetId % 1 == 0 and packetId >= 1,
    "visual topology carries its packet identity"
  )
  assert(type(event.sequence) == "number", "visual topology carries its event sequence")
  local actors = event.actors
  assert(type(actors) == "table" and #actors == 1, "visual topology carries one event actor")
  local targets = event.targets
  assert(type(targets) == "table" and #targets >= 1, "visual topology carries its event targets")
  if type(event.visualSeed) ~= "number" then
    error("visual topology carries its deterministic visual seed", 0)
  end
  local attacker = resolveEntry(packet, actors[1] --[[@as table<string, unknown>]], "actor", slotGeometry)
  local resolved = {} ---@type table<integer, table<string, unknown>>
  for _, target in ipairs(targets) do
    assert(type(target) == "table", "visual topology carries ordered target records")
    resolved[#resolved + 1] = resolveEntry(packet, target --[[@as table<string, unknown>]], "target", slotGeometry)
  end
  local occurrenceEvent = { sequence = event.sequence } ---@type table<string, unknown>
  for _, key in ipairs({ "actionId", "hitIndex", "effectKey" }) do
    if event[key] ~= nil then
      occurrenceEvent[key] = event[key]
    end
  end
  if event.move ~= nil then
    assert(type(event.move) == "table", "visual topology carries its move facts")
    local move = event.move --[[@as table<string, unknown>]]
    local detachedMove = {
      selected = move.selected,
      executed = move.executed,
      phase = move.phase,
    } ---@type table<string, unknown>
    for _, key in ipairs({ "hitOrdinal", "hitCount", "power" }) do
      if move[key] ~= nil then
        detachedMove[key] = move[key]
      end
    end
    occurrenceEvent.move = detachedMove
  end
  if event.suppression ~= nil then
    assert(type(event.suppression) == "table", "visual topology carries its suppression facts")
    local detachedSuppression = {} ---@type table<string, unknown>
    for field, value in
      pairs(event.suppression --[[@as table<string, unknown>]])
    do
      detachedSuppression[field] = value
    end
    occurrenceEvent.suppression = detachedSuppression
  end
  return {
    launchId = launchId,
    packetId = packetId,
    event = occurrenceEvent,
    visualSeed = event.visualSeed,
    topology = { attacker = attacker, targets = resolved },
  }
end

return BattlePresentationFlow
