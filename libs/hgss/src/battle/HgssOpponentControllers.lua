-- Wild and scripted opponent controllers. Wild fighters follow the native
-- roaming policy rather than the trainer policy: every owned actor strikes
-- with its leading move through the shared reply shape, and the move slot
-- replays exactly for a fixed seed. Scripted and tutorial fighters replay
-- only their listed actions in order, consuming one entry per owned
-- request without touching random state; an exhausted list or absent script
-- context fails instead of guessing. Both answer through the same reply
-- shape human and trainer controllers use, so the session validates and
-- settles them identically.

local Errors = require("libs.errors.src.Errors")

---@class HgssOpponentControllers
local HgssOpponentControllers = {}

---@param request table<string, unknown> pending decision request owned by this controller
local function assertRequest(request)
  assert(type(request) == "table", "opponent replies answer pending requests")
  assert(
    type(request.requestId) == "number" and request.requestId % 1 == 0 and request.requestId >= 1,
    "opponent replies name a positive request"
  )
  assert(
    type(request.epoch) == "number" and request.epoch % 1 == 0 and request.epoch >= 0,
    "opponent replies carry a non-negative batch epoch"
  )
  assert(type(request.controller) == "string" and request.controller ~= "", "replies name their controller")
  assert(type(request.actors) == "table" and #request.actors > 0, "replies answer at least one actor")
end

---@param view table<string, unknown> controller observation for this request
---@param actor table<string, unknown> actor whose roster entry is inspected
---@return integer usable move count backing strike selection, at least one
local function ownMoveCount(view, actor)
  if type(view) == "table" and type(view.combatants) == "table" then
    for _, entry in ipairs(view.combatants) do
      if
        type(entry) == "table"
        and type(entry.combatant) == "number"
        and entry.combatant == actor.combatant
        and type(entry.mon) == "table"
        and type(entry.mon.moves) == "table"
        and #entry.mon.moves >= 1
      then
        return #entry.mon.moves
      end
    end
  end
  return 1
end

---@param view table<string, unknown> controller observation for this request
---@return integer retargetable position slot addressed by strikes
local function strikeTarget(view)
  if type(view) == "table" and type(view.opponents) == "table" then
    local first = view.opponents[1]
    if
      type(first) == "table"
      and type(first.position) == "number"
      and first.position % 1 == 0
      and first.position >= 1
    then
      return first.position
    end
  end
  return 1
end

---@param request table<string, unknown> pending decision request owned by this controller
---@param view table<string, unknown> controller observation for this request
---@param rng table<string, unknown> battle stream owned by the caller
---@return table<string, unknown> reply in the shared decision shape
function HgssOpponentControllers.wild(request, view, rng)
  assertRequest(request)
  assert(type(view) == "table", "wild selection reads its controller observation")
  assert(type(rng) == "table" and type(rng.nextU16) == "function", "wild selection draws from the battle stream")
  local target = strikeTarget(view)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    assert(type(actor) == "table", "replies answer actor records")
    local slots = ownMoveCount(view, actor)
    local draw = rng:nextU16("wild_strike", { controller = request.controller, request = request.requestId })
    choices[#choices + 1] = {
      actor = actor,
      kind = "attack",
      payload = { moveSlot = draw % slots, target = { kind = "position", position = target } },
    }
  end
  return {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
end

---@param value unknown
---@return unknown detached copy that cannot reach live state
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

---@param request table<string, unknown> pending decision request owned by this controller
---@param view table<string, unknown> controller observation for this request
---@param stream table<string, unknown> battle stream owned by the caller, never drawn by replays
---@param context table<string, unknown>|nil script binding carrying the acting record and its action list
---@return table<string, unknown> reply in the shared decision shape
function HgssOpponentControllers.scripted(request, view, stream, context)
  assertRequest(request)
  assert(type(view) == "table", "scripted replays read their controller observation")
  assert(type(stream) == "table" or stream == nil, "scripted replays carry their stream handle without drawing from it")
  if type(context) ~= "table" or type(context.script) ~= "table" or type(context.actor) ~= "table" then
    Errors.raise("SCRIPT_CONTEXT_MISSING", "scripted fighters replay only through an explicit script binding", {
      request = request.requestId,
    })
  end
  assert(type(context) == "table", "scripted fighters replay only through an explicit script binding")
  assert(type(context.script) == "table", "script bindings list their actions in order")
  assert(type(context.actor) == "table", "script bindings name their acting record")
  local script = context.script
  assert(type(script.actions) == "table", "script bindings list their actions in order")
  local cursor = script.cursor or 1
  assert(type(cursor) == "number" and cursor % 1 == 0 and cursor >= 1, "script bindings track their next action")
  local action = script.actions[cursor]
  if type(action) ~= "table" then
    Errors.raise("SCRIPT_LIST_EXHAUSTED", "scripted fighters never invent actions past their list", {
      request = request.requestId,
      cursor = cursor,
    })
  end
  local listed = action --[[@as table<string, unknown>]]
  assert(type(listed.kind) == "string", "listed script actions name their kind")
  assert(type(listed.payload) == "table", "listed script actions carry their payload record")
  script.cursor = cursor + 1
  return {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = { { actor = context.actor, kind = listed.kind, payload = copyValue(listed.payload) } },
  }
end

return HgssOpponentControllers
