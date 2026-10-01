-- Shared native move continuation and hit loop: the action-to-move
-- transition spends power points from the owning slot, separates the
-- requested, executing, and power-point-owning moves, resolves called
-- moves through the called-move owner, and validates every published
-- frame before stepping it. Steps dispatch on the executing move through
-- the native registry, resume pushed frames without repeating completed
-- operations, and settle failed selections without events, draws, or
-- power-point effects. Unknown moves fail loudly instead of falling back
-- to generic damage. Source references:
-- src/battle/battle_controller_player.c and src/battle/battle_command.c.

local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local CalledMoves = require("libs.battle.src.gen4.behaviors.moves.CalledMoves")
local MoveSelection = require("libs.battle.src.gen4.MoveSelection")
local NativeMoves = require("libs.battle.src.gen4.behaviors.NativeMoves")

---@class MoveExecution
local MoveExecution = {}

local cachedHandlers = nil

---@return table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> executable native handlers by move identity
local function handlers()
  if cachedHandlers == nil then
    local bound = {}
    NativeMoves.register(bound)
    cachedHandlers = bound
  end
  return cachedHandlers --[[@as table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>>]]
end

---@param value unknown value under test
---@param what string field under test
---@return integer the value once it proves a positive integer
local function checkId(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    error(BattleErrors.invalidState("move frames carry a positive integer " .. what, {}))
  end
  return value --[[@as integer]]
end

---@param value unknown value under test
---@return table<string, unknown> the value once it proves a record
local function checkRecord(value)
  if type(value) ~= "table" then
    error(BattleErrors.invalidState("move frames carry records", {}))
  end
  return value --[[@as table<string, unknown>]]
end

---@param moves unknown power-point store under test
---@param slot integer zero-based power-point slot under spending
local function spendPp(moves, slot)
  if type(moves) ~= "table" then
    error(BattleErrors.invalidState("move execution spends from its power-point store", {}))
  end
  local entries = moves --[[@as table<integer, unknown>]]
  local entry = entries[slot + 1]
  if type(entry) ~= "table" then
    error(BattleErrors.invalidState("move execution spends from a known power-point slot", { slot = slot }))
  end
  local record = entry --[[@as table<string, unknown>]]
  if type(record.pp) ~= "number" or record.pp % 1 ~= 0 or record.pp < 1 then
    error(BattleErrors.invalidState("move execution spends a remaining power point", { slot = slot }))
  end
  record.pp = record.pp --[[@as integer]] - 1
end

---@param inputs table<string, unknown> transition inputs under the action-to-move transition
local function checkTransitionInputs(inputs)
  checkRecord(inputs)
  checkId(inputs.actionId, "action identifier")
  local actor = checkRecord(inputs.actor)
  if type(actor.combatant) ~= "number" then
    error(BattleErrors.invalidState("move frames name their user combatant", {}))
  end
  if type(inputs.requestedMove) ~= "string" or inputs.requestedMove == "" then
    error(BattleErrors.invalidState("move frames name their requested move", {}))
  end
  if type(inputs.executingMove) ~= "string" or inputs.executingMove == "" then
    error(BattleErrors.invalidState("move frames name their executing move", {}))
  end
  checkRecord(inputs.selectedTarget)
  local targets = inputs.targets
  if
    type(targets) ~= "table"
    or #targets --[[@as table<integer, unknown>]]
      == 0
  then
    error(BattleErrors.invalidState("move frames carry their sampled targets", {}))
  end
  if inputs.ppOwnerSlot ~= nil then
    local slot = inputs.ppOwnerSlot
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
      error(BattleErrors.invalidState("move frames name a non-negative power-point owner", {}))
    end
  end
end

---@param entries table<integer, unknown> sampled targets under copying
---@return table<integer, unknown> detached target list for the frame
local function copyTargets(entries)
  local copy = {}
  for index = 1, #entries do
    copy[index] = entries[index]
  end
  return copy
end

--- Validates a move frame shape plus its move-specific facts: friendship
--- moves require their explicit friendship fact instead of defaulting.
---@param frame table<string, unknown> move frame under validation
---@return table<string, unknown> the validated move frame
function MoveExecution.validateFrame(frame)
  checkRecord(frame)
  checkId(frame.actionId, "action identifier")
  local actor = checkRecord(frame.actor)
  if type(actor.combatant) ~= "number" then
    error(BattleErrors.invalidState("move frames name their user combatant", {}))
  end
  if type(frame.requestedMove) ~= "string" or frame.requestedMove == "" then
    error(BattleErrors.invalidState("move frames name their requested move", {}))
  end
  if type(frame.executingMove) ~= "string" or frame.executingMove == "" then
    error(BattleErrors.invalidState("move frames name their executing move", {}))
  end
  if frame.ppOwnerSlot ~= nil then
    local slot = frame.ppOwnerSlot
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
      error(BattleErrors.invalidState("move frames name a non-negative power-point owner", {}))
    end
  end
  if frame.calledBy ~= nil and (type(frame.calledBy) ~= "string" or frame.calledBy == "") then
    error(BattleErrors.invalidState("move frames name their calling move", {}))
  end
  checkRecord(frame.selectedTarget)
  local targets = frame.targets
  if
    type(targets) ~= "table"
    or #targets --[[@as table<integer, unknown>]]
      == 0
  then
    error(BattleErrors.invalidState("move frames carry their sampled targets", {}))
  end
  if type(frame.moves) ~= "table" then
    error(BattleErrors.invalidState("move frames carry their power-point store", {}))
  end
  if type(frame.stream) ~= "table" then
    error(BattleErrors.invalidState("move frames carry their battle stream", {}))
  end
  local stream = frame.stream --[[@as table<string, unknown>]]
  if type(stream.nextU16) ~= "function" then
    error(BattleErrors.invalidState("move frames carry their battle stream", {}))
  end
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "move frames draw from the native battle stream")
  local locals = checkRecord(frame.locals)
  if frame.executingMove == "FRUSTRATION" or frame.executingMove == "RETURN" then
    local friendship = locals.friendship
    if type(friendship) ~= "number" or friendship % 1 ~= 0 or friendship < 0 or friendship > 255 then
      error(BattleErrors.invalidState("friendship moves read their explicit friendship fact", {}))
    end
  end
  return frame
end

--- Runs the action-to-move transition: resolves selection, draws called
--- moves, spends exactly one power point from the owning slot, and
--- publishes the validated move frame. Failed selections publish without
--- spending, drawing, or emitting.
---@param inputs table<string, unknown> transition inputs carrying action, actor, moves, stream, targets, and calling facts
---@return table<string, unknown> validated move frame for the hit loop
function MoveExecution.start(inputs)
  checkTransitionInputs(checkRecord(inputs))
  local plan = MoveSelection.resolveExecution(inputs)
  local decision = CalledMoves.choose({
    requestedMove = plan.requestedMove,
    executingMove = plan.executingMove,
    stream = plan.stream,
    party = plan.party,
    usable = plan.usable,
    copiedMove = plan.copiedMove,
  })
  local executing = plan.executingMove --[[@as string]]
  local failed = nil
  if decision ~= nil then
    if decision.failed ~= nil then
      failed = decision.failed
    else
      executing = decision.executingMove
    end
  end
  if failed == nil then
    if handlers()[executing] == nil then
      error(
        BattleErrors.missingBehavior("no native move handler is bound for the source identity", { key = executing })
      )
    end
    if plan.ppOwnerSlot ~= nil then
      spendPp(plan.moves, plan.ppOwnerSlot --[[@as integer]])
    end
  end
  local actor = plan.actor --[[@as table<string, unknown>]]
  local actorCopy = {}
  for key, value in pairs(actor) do
    actorCopy[key] = value
  end
  local frame = {
    actionId = plan.actionId,
    actor = actorCopy,
    requestedMove = plan.requestedMove,
    executingMove = executing,
    ppOwnerSlot = plan.ppOwnerSlot,
    calledBy = plan.calledBy,
    selectedTarget = plan.selectedTarget,
    targets = copyTargets(plan.targets --[[@as table<integer, unknown>]]),
    targetIndex = 1,
    hitIndex = 0,
    plannedHits = nil,
    aggregateDamage = 0,
    moves = plan.moves,
    stream = plan.stream,
    locals = {},
  }
  local locals = frame.locals --[[@as table<string, unknown>]]
  if failed ~= nil then
    locals.failed = failed
  end
  for _, key in ipairs({ "friendship", "party", "usable", "status", "copiedMove", "combat" }) do
    if plan[key] ~= nil then
      locals[key] = plan[key]
    end
  end
  return MoveExecution.validateFrame(frame)
end

--- Advances one move frame through the native registry. Completed results
--- pass through untouched, pushed frames resume behind their cursor, and
--- failed selections settle without side effects.
---@param ctx BattleContext mechanics context under execution
---@param node table<string, unknown> move frame or execution step under advancement
---@return table<string, unknown> terminal or pushed execution step
function MoveExecution.step(ctx, node)
  if type(ctx) ~= "table" then
    error(BattleErrors.invalidState("move execution steps through the battle context", {}))
  end
  if type(node) ~= "table" then
    error(BattleErrors.invalidState("move execution steps from a frame or step record", {}))
  end
  local record = node --[[@as table<string, unknown>]]
  if record.kind == "complete" and record.frame == nil then
    return record
  end
  if record.frame ~= nil then
    return MoveExecution.step(ctx, record.frame --[[@as table<string, unknown>]])
  end
  local frame = MoveExecution.validateFrame(record)
  local locals = frame.locals --[[@as table<string, unknown>]]
  if locals.failed ~= nil then
    return { kind = "complete", result = "failed" }
  end
  local handler = handlers()[
    frame.executingMove --[[@as string]]
  ]
  if handler == nil then
    error(BattleErrors.missingBehavior("no native move handler is bound for the source identity", {
      key = frame.executingMove --[[@as string]],
    }))
  end
  return handler(ctx, frame)
end

return MoveExecution
