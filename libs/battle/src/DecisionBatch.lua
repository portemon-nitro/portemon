-- Shared pending-batch decision admission for the two battle session
-- executors. Both families seal one decision batch at a time over the
-- same reservation maps; this owner holds the request envelope, the
-- actor-context checks, and the atomic publish so the families cannot
-- drift on protocol rules. Battle law stays with the callers: each
-- submit carries a binding callback that judges one choice against the
-- staged reservations, and only the common action checks live here.

local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")
local BattleState = require("libs.battle.src.BattleState")

---@class DecisionBatch
local DecisionBatch = {}

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

--- Canonicalizes one reply actor for equality bookkeeping: roster-scoped
--- prompts omit the entry token, so absence matches absence on both
--- sides of the comparison without ever writing a zero into protocol
--- data. Live-entry batches always carry tokens on both sides.
---@param combatant integer addressed roster identity
---@param activation integer? addressed entry token, when the prompt is entry-scoped
---@return string
local function actorKey(combatant, activation)
  return combatant .. ":" .. (activation or "")
end

---@param state table<string, unknown>
---@return table<integer, table<string, unknown>> pending requests in batch order
function DecisionBatch.requests(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  local batch = pending.batch --[[@as table<string, unknown>]]
  return batch.requests --[[@as table<integer, table<string, unknown>>]]
end

---@param state table<string, unknown>
---@return boolean true once every open request holds a stored reply
function DecisionBatch.isComplete(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  for _, request in ipairs(DecisionBatch.requests(state)) do
    if
      submitted[
        request.requestId --[[@as integer]]
      ] == nil
    then
      return false
    end
  end
  return true
end

---@param state table<string, unknown>
---@return table<string, unknown> detached open batch without sealed replies
function DecisionBatch.view(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  return copyValue(pending.batch) --[[@as table<string, unknown>]]
end

---@param state table<string, unknown>
---@param request table<string, unknown>
---@param reply table<string, unknown>
---@return table<string, unknown>? input error, or nil when the reply stores
local function checkReplyContext(state, request, reply)
  local pending = state.pending --[[@as table<string, unknown>]]
  local batch = pending.batch --[[@as table<string, unknown>]]
  if reply.controller ~= request.controller then
    return BattleErrors.input("controllers answer only their own requests", {
      request = request.requestId,
    })
  end
  if reply.epoch ~= batch.epoch then
    return BattleErrors.input("replies must carry their batch epoch", { request = request.requestId })
  end
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  if
    submitted[
      request.requestId --[[@as integer]]
    ] ~= nil
  then
    return BattleErrors.input("duplicate replies cannot answer twice", { request = request.requestId })
  end
  local actors = request.actors --[[@as table<integer, table<string, unknown>>]]
  local choices = reply.choices --[[@as table<integer, table<string, unknown>>]]
  if #choices ~= #actors then
    return BattleErrors.input("replies must answer every addressed actor exactly once", {
      request = request.requestId,
    })
  end
  local expected = {}
  for _, actor in ipairs(actors) do
    expected[
      actorKey(actor.combatant --[[@as integer]], actor.activation --[[@as integer?]])
    ] = actor
  end
  local seen = {}
  for _, choice in ipairs(choices) do
    local actor = choice.actor --[[@as table<string, unknown>]]
    local key = actorKey(actor.combatant --[[@as integer]], actor.activation --[[@as integer?]])
    if expected[key] == nil or seen[key] ~= nil then
      return BattleErrors.input("replies must address exactly the requested entries", {
        request = request.requestId,
      })
    end
    seen[key] = true
  end
  return nil
end

--- Runs the common action-reference and reservation checks for one
--- choice against the staged reservations: the actor still holds its
--- live entry, strikes name declared targets, exchanges name a benched
--- roster-mate reserved at most once per batch, and bag use names a
--- declared inventory holding an unclaimed unit. Prompt kinds that do
--- not address live entries never reach this check.
---@param state table<string, unknown> live battle state under reply validation
---@param choice table<string, unknown> validated decision choice under binding
---@param reserved table<string, unknown> staged reservation maps for this reply
---@return table<string, unknown>? input error, or nil when the choice binds
function DecisionBatch.checkActionBinding(state, choice, reserved)
  local actor = choice.actor --[[@as table<string, unknown>]]
  local payload = choice.payload --[[@as table<string, unknown>]]
  local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
  local active = combatant.active --[[@as table<string, unknown>]]
  if active == nil or active.activation ~= actor.activation then
    return BattleErrors.input("locked references die with their entry", {
      combatant = actor.combatant,
    })
  end
  if choice.kind == "attack" then
    local target = payload.target --[[@as table<string, unknown>]]
    if target.kind == "position" then
      if
        (state.positions --[[@as table<integer, table<string, unknown>>]])[
          target.position --[[@as integer]]
        ] == nil
      then
        return BattleErrors.input("strikes must name a declared position", {})
      end
    elseif target.kind == "combatant" then
      if
        (state.combatants --[[@as table<integer, table<string, unknown>>]])[
          target.combatant --[[@as integer]]
        ] == nil
      then
        return BattleErrors.input("strikes must name a declared combatant", {})
      end
    elseif target.kind == "side" then
      if
        (state.sides --[[@as table<integer, table<string, unknown>>]])[
          target.side --[[@as integer]]
        ] == nil
      then
        return BattleErrors.input("strikes must name a declared side", {})
      end
    end
  elseif choice.kind == "switch" then
    local replacement = (state.combatants --[[@as table<integer, table<string, unknown>>]])[
      payload.replacement --[[@as integer]]
    ]
    if replacement == nil then
      return BattleErrors.input("replacements must name a declared combatant", {})
    end
    if replacement.participant ~= combatant.participant then
      return BattleErrors.input("replacements must share the actor roster", {})
    end
    if replacement.active ~= nil then
      return BattleErrors.input("replacements must start benched", {})
    end
    local taken = (reserved.replacements --[[@as table<integer, integer>]])[
      payload.replacement --[[@as integer]]
    ]
    if taken ~= nil then
      return BattleErrors.input("replacements are reserved once per batch", {})
    end
  elseif choice.kind == "item" then
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    if participant.inventoryId == nil then
      return BattleErrors.input("item use requires a declared inventory", {})
    end
    local inventory = (state.inventories --[[@as table<string, table<string, unknown>>]])[
      participant.inventoryId --[[@as string]]
    ]
    if inventory == nil then
      return BattleErrors.input("item use requires a known inventory", {})
    end
    local quantities = inventory.quantities --[[@as table<string, integer>]]
    local stock = quantities[
      payload.item --[[@as string]]
    ] or 0
    local held = reserved.items --[[@as table<string, table<string, integer>>]]
    local claimed = 0
    if
      held[
        participant.inventoryId --[[@as string]]
      ] ~= nil
    then
      claimed = held[
        participant.inventoryId --[[@as string]]
      ][
        payload.item --[[@as string]]
      ] or 0
    end
    if stock - claimed < 1 then
      return BattleErrors.input("item use requires reserved stock", { item = payload.item })
    end
  end
  return nil
end

---@param state table<string, unknown> live battle state under reservation accounting
---@param request table<string, unknown> open request the stored choices answer
---@param choice table<string, unknown> accepted choice promising shared stock
---@param staged table<string, unknown> staged reservation maps for this reply
local function accountReservation(state, request, choice, staged)
  local payload = choice.payload --[[@as table<string, unknown>]]
  if choice.kind == "switch" then
    local taken = staged.replacements --[[@as table<integer, integer>]]
    taken[
      payload.replacement --[[@as integer]]
    ] = request.requestId --[[@as integer]]
  elseif choice.kind == "item" then
    local actor = choice.actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    local inventoryId = participant.inventoryId --[[@as string?]]
    if inventoryId ~= nil then
      local held = staged.items --[[@as table<string, table<string, integer>>]]
      if held[inventoryId] == nil then
        held[inventoryId] = {}
      end
      held[inventoryId][
        payload.item --[[@as string]]
      ] = (
        held[inventoryId][
          payload.item --[[@as string]]
        ] or 0
      ) + 1
    end
  end
end

--- Admits one sealed reply into the open batch. The reply shape is
--- validated against its request kind, the controller/epoch/actor
--- envelope is checked, then every choice is judged through the caller
--- binding callback against reservations staged privately for this
--- reply: each accepted choice is accounted before its sibling is
--- judged, so siblings cannot overbook shared stock or one reserve.
--- The detached reply and the final reservation maps publish only after
--- every choice passes; any failure publishes neither. Unexpected
--- lookup errors from the callback propagate instead of coercing into
--- input errors.
---@param state table<string, unknown> live battle state holding the open batch
---@param reply table<string, unknown> sealed controller reply under admission
---@param validateBinding fun(choice: table<string, unknown>, reserved: table<string, unknown>): table<string, unknown>? read-only choice judge over the staged reservations
---@return boolean stored true once the reply is kept
---@return table<string, unknown>? input error when the reply is rejected
---@return integer? stored request identity on success
function DecisionBatch.submit(state, reply, validateBinding)
  assert(type(validateBinding) == "function", "batch admission judges choices through its caller")
  if type(reply) ~= "table" or type(reply.requestId) ~= "number" then
    return false, BattleErrors.input("decision replies must name a positive request", {}), nil
  end
  if state.status ~= "waiting" or state.pending == nil then
    return false, BattleErrors.input("replies require an open decision batch", {}), nil
  end
  local wanted = nil
  for _, request in ipairs(DecisionBatch.requests(state)) do
    if request.requestId == reply.requestId then
      wanted = request
    end
  end
  if wanted == nil then
    return false, BattleErrors.input("replies must answer an open request", {}), nil
  end
  local ok, validated = pcall(BattleProtocol.validateReply, reply, wanted.kind --[[@as string]])
  if not ok then
    return false,
      validated, --[[@as table<string, unknown>]]
      nil
  end
  local stored = validated --[[@as table<string, unknown>]]
  local contextError = checkReplyContext(state, wanted, stored)
  if contextError ~= nil then
    return false, contextError, nil
  end
  local live = state.pending --[[@as table<string, unknown>]]
  local current = live.reserved --[[@as table<string, unknown>]]
  local staged = { replacements = {}, items = {} }
  for id, holder in
    pairs(current.replacements --[[@as table<integer, integer>]])
  do
    (staged.replacements --[[@as table<integer, integer>]])[id] = holder
  end
  for inventoryId, stock in
    pairs(current.items --[[@as table<string, table<string, integer>>]])
  do
    local copied = {}
    for item, count in pairs(stock) do
      copied[item] = count
    end
    (staged.items --[[@as table<string, table<string, integer>>]])[inventoryId] = copied
  end
  for _, choice in
    ipairs(stored.choices --[[@as table<integer, table<string, unknown>>]])
  do
    local bindingError = validateBinding(choice, staged)
    if bindingError ~= nil then
      return false, bindingError, nil
    end
    accountReservation(state, wanted, choice, staged)
  end
  local pending = state.pending --[[@as table<string, unknown>]]
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  submitted[
    wanted.requestId --[[@as integer]]
  ] = copyValue(stored) --[[@as table<string, unknown>]]
  pending.reserved = staged
  return true, nil, wanted.requestId --[[@as integer]]
end

return DecisionBatch
