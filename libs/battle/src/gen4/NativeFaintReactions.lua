-- Resolves faint-triggered battle effects from the current strike ledger.
local BattleContext = require("libs.battle.src.BattleContext")
local BattleState = require("libs.battle.src.BattleState")

local M = {}

---@param state table<string, unknown> live battle state under reactive faint resolution
function M.resolve(state)
  local lastHits = state.lastHits
  local strikes = state.turnStrikes
  if type(lastHits) ~= "table" or type(strikes) ~= "table" then
    return
  end
  local context = BattleContext.wrap(state)
  local pending = {} ---@type integer[]
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.active ~= nil
      and combatant.hp --[[@as integer]]
        <= 0
    then
      pending[#pending + 1] = combatantId
    end
  end
  for _, faintedId in ipairs(pending) do
    local hasDestinyBond = context:hasBattleEffect(faintedId, "destinybond")
    local hasGrudge = context:hasBattleEffect(faintedId, "grudge")
    if hasDestinyBond or hasGrudge then
      -- Clear the one-turn markers before applying their consequences so a
      -- later faint sweep cannot react to the same knockout again.
      context:removeBattleEffect(faintedId, "destinybond")
      context:removeBattleEffect(faintedId, "grudge")
      local recorded = (strikes --[[@as table<integer, unknown>]])[faintedId]
      local hit = (lastHits --[[@as table<integer, unknown>]])[faintedId]
      if type(recorded) == "table" and type(hit) == "table" then
        local strike = recorded --[[@as table<string, unknown>]]
        local received = hit --[[@as table<string, unknown>]]
        local attackerId = received.user
        if type(attackerId) == "number" and strike.lastAny == attackerId then
          local attacker = BattleState.combatant(state, attackerId --[[@as integer]])
          local fainted = BattleState.combatant(state, faintedId)
          local attackerSide = BattleState.participant(state, attacker.participant --[[@as integer]]).side
          local faintedSide = BattleState.participant(state, fainted.participant --[[@as integer]]).side
          if
            attacker.active ~= nil
            and attacker.hp --[[@as integer]]
              > 0
            and attackerSide ~= faintedSide
          then
            if hasDestinyBond then
              context:damage(attackerId --[[@as integer]], 999999, { kind = "destinybond", combatant = faintedId })
            end
            if
              hasGrudge
              and attacker.hp --[[@as integer]]
                > 0
            then
              local move = received.move
              local lastHitSlots = state.lastHitSlots --[[@as table<integer, integer>]]
              local slot = lastHitSlots[faintedId]
              if move ~= "STRUGGLE" and type(slot) == "number" and slot % 1 == 0 and slot >= 0 then
                local moves = attacker.mon.moves --[[@as table<integer, table<string, unknown>>]]
                local moveSlot = moves[slot + 1]
                assert(type(moveSlot) == "table", "Grudge drains the selected PP owner")
                moveSlot.pp = 0
              end
            end
          end
        end
      end
    end
  end
end

return M
