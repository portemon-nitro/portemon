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

---@class BattlePresentationFlow
local BattlePresentationFlow = {}

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
---@return string? staged victory fanfare symbol for wins, nil when the word carries no fanfare
function BattlePresentationFlow.resultFanfare(word, wild)
  if word ~= "win" then
    return nil
  end
  if wild then
    return "SEQ_GS_WIN1"
  end
  return "SEQ_GS_WIN2"
end

return BattlePresentationFlow
