-- Stages a selected native move around activation-scoped charge and lock state.
local BattleErrors = require("libs.battle.src.errors")
local BattleContext = require("libs.battle.src.BattleContext")
local BattleState = require("libs.battle.src.BattleState")
local SequenceMoveState = require("libs.battle.src.gen4.SequenceMoveState")

local M = {}

---@class NativeSequenceActionStage
---@field move string selected or forced move identity
---@field priority integer compiled priority adjusted for Pursuit interception
---@field forcedMove string? move identity forced by a stored sequence

---@param mon unknown battle-local mon record under move resolution
---@param moveSlot unknown zero-based move slot under resolution
---@return string move identity to execute
local function resolveMove(mon, moveSlot)
  if type(mon) == "table" and type(moveSlot) == "number" and moveSlot % 1 == 0 and moveSlot >= 0 then
    local moves = (mon --[[@as table<string, unknown>]]).moves
    if type(moves) == "table" then
      local entry = (moves --[[@as table<integer, unknown>]])[
        moveSlot --[[@as integer]] + 1
      ]
      if type(entry) == "table" then
        local move = (entry --[[@as table<string, unknown>]]).move
        local pp = (entry --[[@as table<string, unknown>]]).pp
        if type(move) == "string" and move ~= "" and type(pp) == "number" and pp % 1 == 0 and pp >= 1 then
          return move
        end
      end
    end
  end
  return "STRUGGLE"
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts
---@param move string selected or forced move identity
---@return integer compiled native move priority
local function movePriority(moveFacts, move)
  local facts = moveFacts[move]
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("ordering reads its compiled move priority", { key = move }))
  end
  local priority = facts.priority
  if type(priority) ~= "number" or priority % 1 ~= 0 then
    error(BattleErrors.missingBehavior("ordering reads its compiled move priority", { key = move }))
  end
  return priority --[[@as integer]]
end

---@param state table<string, unknown> live battle state
---@param choices table<integer, table<string, unknown>> committed choices for the turn
---@param combatant integer active combatant selecting a move
---@param mon unknown selected actor's battle-local mon record
---@param payload table<string, unknown> validated attack payload
---@param moveFacts table<string, table<string, unknown>> immutable move facts
---@param switchPriority integer ordering bracket above a voluntary switch
---@return NativeSequenceActionStage staged move identity, priority, and optional forced identity
function M.stage(state, choices, combatant, mon, payload, moveFacts, switchPriority)
  local selectedMove = resolveMove(mon, payload.moveSlot)
  if selectedMove ~= "RAGE" then
    BattleContext.wrap(state):removeBattleEffect(combatant, "rage")
  end
  local forcedMove = SequenceMoveState.forcedMove(state, combatant)
  local move = forcedMove or selectedMove
  local priority = movePriority(moveFacts, move)
  if move == "PURSUIT" then
    local target = (payload.target --[[@as table<string, unknown>]]).combatant
    if payload.target.kind == "position" then
      target = BattleState.position(state, payload.target.position --[[@as integer]]).occupant
    end
    for _, planned in ipairs(choices) do
      local plannedChoice = planned.choice --[[@as table<string, unknown>]]
      local switchActor = plannedChoice.actor --[[@as table<string, unknown>]]
      if plannedChoice.kind == "switch" and switchActor.combatant == target then
        priority = switchPriority
        break
      end
    end
  end
  return { move = move, priority = priority, forcedMove = forcedMove }
end

return M
