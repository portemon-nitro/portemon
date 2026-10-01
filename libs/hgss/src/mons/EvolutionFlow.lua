-- Concrete typed evolution flow over the pure mon planning owner. The flow
-- stages exactly one candidate result: it opens on the source-permitted
-- confirmation, works the ordered evolution learning through the shared
-- progression owner (free move slots fill silently while a full set pauses
-- for an explicit replace-or-decline decision, mirroring battle learning),
-- and publishes the whole result at once on capture. Driving the flow never
-- touches the live mon; cancelling stages nothing and stays retryable.
-- Post-battle eligibility rechecks final roster state behind the terminal
-- result instead of serving stale mid-battle snapshots.

local Evolution = require("libs.mons.src.gen4.Evolution")
local LevelProgression = require("libs.mons.src.gen4.LevelProgression")
local Moves = require("libs.mons.src.gen4.Moves")

---@class EvolutionFlow
local EvolutionFlow = {}

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param flow table<string, unknown>
local function checkFlow(flow)
  assert(type(flow) == "table", "evolution flows read their flow record")
  assert(type(flow._plan) == "table", "evolution flows carry their staged plan")
  assert(type(flow._staged) == "table", "evolution flows carry their staged mon")
end

---@param mon table<string, unknown>
---@param move unknown
---@return boolean
local function knowsMove(mon, move)
  for _, entry in ipairs(mon.moves) do
    if type(entry) == "table" and entry.move == move then
      return true
    end
  end
  return false
end

---@param opportunity table<string, unknown>
---@param staged table<string, unknown>
---@return table<string, unknown>
local function learnPrompt(opportunity, staged)
  local current = {}
  for _, entry in ipairs(assert(staged.moves, "learning prompts read the staged moves")) do
    assert(type(entry) == "table", "staged moves carry entry records")
    current[#current + 1] = entry.move
  end
  return {
    prompt = "learn_move",
    move = opportunity.move,
    level = opportunity.level,
    currentMoves = current,
  }
end

-- Opens a flow for the first matching candidate, or nil when the mon is
-- ineligible. The input stays live-owned; the flow works private copies.
---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown>?
function EvolutionFlow.start(mon, context, catalog)
  assert(type(mon) == "table", "evolution flows read a mon record")
  assert(type(context) == "table", "evolution flows read a trigger context")
  assert(catalog ~= nil, "evolution flows read a catalog")
  local plan = Evolution.plan(mon, context, catalog)
  if plan == nil then
    return nil
  end
  local staged = copyValue(plan.monAfter)
  assert(type(staged) == "table", "evolution flows copy the staged mon")
  return {
    _plan = plan,
    _catalog = catalog,
    _staged = staged,
    _confirmed = false,
    _cancelled = false,
    _complete = false,
    _cursor = 1,
    _pending = nil,
    _result = nil,
  }
end

-- Reports the next prompt: the opening confirmation, one learning decision
-- per full-set opportunity, or the terminal descriptor. Free move slots
-- fill silently inside the step; already-known opportunities are skipped.
---@param flow table<string, unknown>
---@return table<string, unknown>
function EvolutionFlow.step(flow)
  checkFlow(flow)
  if flow._cancelled then
    return { prompt = "cancelled" }
  end
  local plan = flow._plan
  if not flow._confirmed then
    return {
      prompt = "confirm_evolution",
      species = plan.monAfter.species,
      canCancel = plan.canCancel,
    }
  end
  if flow._pending ~= nil then
    return learnPrompt(flow._pending, flow._staged)
  end
  local catalog = assert(flow._catalog, "evolution flows read their catalog")
  local opportunities = assert(plan.learningOpportunities, "evolution flows read staged learning")
  while flow._cursor <= #opportunities do
    local opportunity = opportunities[flow._cursor]
    assert(type(opportunity) == "table", "learning opportunities are records")
    if knowsMove(flow._staged, opportunity.move) then
      flow._cursor = flow._cursor + 1
    elseif #flow._staged.moves < Moves.MAX_SLOTS then
      local filled = LevelProgression.learn(flow._staged, opportunity.move, catalog)
      assert(filled.applied, "a free move slot accepts evolution learning")
      flow._staged = filled.mon
      flow._cursor = flow._cursor + 1
    else
      flow._pending = opportunity
      return learnPrompt(opportunity, flow._staged)
    end
  end
  flow._complete = true
  return { prompt = "complete" }
end

-- Answers the outstanding prompt: accept or cancel the confirmation, or
-- replace-or-decline a learning prompt. A consumed decision lands exactly
-- once; cancelling a non-cancellable result and answering a resolved flow
-- both fail loudly.
---@param flow table<string, unknown>
---@param reply table<string, unknown>
function EvolutionFlow.respond(flow, reply)
  checkFlow(flow)
  assert(type(reply) == "table", "flow replies form a record")
  assert(not flow._complete and not flow._cancelled, "the flow already resolved its prompts")
  if flow._pending ~= nil then
    local pending = flow._pending
    local choice = reply.choice
    if choice == "decline" then
      LevelProgression.decline(flow._staged, pending.move)
      flow._cursor = flow._cursor + 1
      flow._pending = nil
      return
    end
    if choice == "replace" then
      local slot = reply.slot
      assert(
        type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot < #flow._staged.moves,
        "replacements name a held zero-based move slot"
      )
      local catalog = assert(flow._catalog, "evolution flows read their catalog")
      flow._staged = LevelProgression.replace(flow._staged, slot, pending.move, catalog)
      flow._cursor = flow._cursor + 1
      flow._pending = nil
      return
    end
    assert(false, "learning replies decline or replace the incoming move")
  end
  assert(not flow._confirmed, "the confirmation is already answered")
  local choice = reply.choice
  if choice == "accept" then
    flow._confirmed = true
    return
  end
  if choice == "cancel" then
    assert(flow._plan.canCancel, "this evolution cannot be cancelled")
    flow._cancelled = true
    return
  end
  assert(false, "confirmations accept or cancel the evolution")
end

-- Captures the staged result once the flow is accepted and complete;
-- anything earlier, or any cancelled flow, captures nothing. Repeated
-- captures stage nothing further.
---@param flow table<string, unknown>
---@return table<string, unknown>?
function EvolutionFlow.capture(flow)
  checkFlow(flow)
  if not flow._confirmed or not flow._complete or flow._cancelled then
    return nil
  end
  if flow._result == nil then
    flow._result = {
      mon = flow._staged,
      additionalMons = flow._plan.additionalMons,
      inventoryDeltas = flow._plan.inventoryDeltas,
    }
  end
  return flow._result
end

-- Rechecks final roster state behind the terminal result, in party order:
-- wins, captures, and flights stage qualifying members while any other
-- outcome stages nothing. The check runs the level trigger per member over
-- the evaluated party, never a stale mid-battle snapshot.
---@param party table<integer, table<string, unknown>>
---@param outcome string
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@return integer[]
function EvolutionFlow.eligibleAfterBattle(party, outcome, context, catalog)
  assert(type(party) == "table", "post-battle eligibility reads the final party")
  assert(type(outcome) == "string", "post-battle eligibility reads the terminal result")
  assert(type(context) == "table", "post-battle eligibility reads the world context")
  assert(catalog ~= nil, "post-battle eligibility reads a catalog")
  if outcome ~= "win" and outcome ~= "caught" and outcome ~= "fled" then
    return {}
  end
  local eligible = {}
  for index, mon in ipairs(party) do
    local scoped = {}
    for key, value in pairs(context) do
      scoped[key] = value
    end
    scoped.party = party
    scoped.trigger = { kind = "level" }
    if Evolution.check(mon, scoped, catalog) ~= nil then
      eligible[#eligible + 1] = index
    end
  end
  return eligible
end

return EvolutionFlow
