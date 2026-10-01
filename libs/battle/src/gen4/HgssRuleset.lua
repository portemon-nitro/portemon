-- Native ruleset binding. The ruleset carries the complete lifecycle
-- handlers the native schedule drives, binds them before gameplay, and
-- advances one schedule step per frame. Missing handlers fail at
-- construction, stepping before binding or after release fails loudly, and
-- the bound session is validated without retaining its mutable state.

local HgssSchedule = require("libs.battle.src.gen4.HgssSchedule")

---@class HgssRuleset
---@field private _handlers table<string, function>
---@field private _bound boolean
---@field private _finalized boolean
local HgssRuleset = {}
HgssRuleset.__index = HgssRuleset

HgssRuleset.HANDLERS = { "openTurn", "executeAction", "applyResiduals", "closeTurn" }

---@param handlers table<string, function> complete lifecycle handlers
---@return HgssRuleset
function HgssRuleset.new(handlers)
  assert(type(handlers) == "table", "native rulesets bind their lifecycle handlers")
  local bound = {} ---@type table<string, function>
  for _, name in ipairs(HgssRuleset.HANDLERS) do
    assert(type(handlers[name]) == "function", "native rulesets bind " .. name .. " before gameplay")
    bound[name] = handlers[name]
  end
  return setmetatable({ _handlers = bound, _bound = false, _finalized = false }, HgssRuleset)
end

---@param session table<string, unknown> live battle session under validation
---@return boolean
function HgssRuleset:initialize(session)
  assert(type(session) == "table", "native rulesets bind to an explicit session")
  assert(not self._bound, "native rulesets bind once")
  assert(not self._finalized, "released rulesets never rebind")
  self._bound = true
  return true
end

---@param queue ScheduledAction[]
---@param frame NativeScheduleFrame
---@param stream BattleRng
---@param budget integer? operations this call may spend before yielding
---@return ScheduledAction? due the next queued action, or nil when suspended
function HgssRuleset:advanceFrame(queue, frame, stream, budget)
  assert(self._bound, "native rulesets advance only after binding")
  assert(not self._finalized, "released rulesets advance nothing")
  return HgssSchedule.step(queue, frame, stream, budget)
end

---@param name string lifecycle phase naming a bound handler
---@return function handler bound at construction
function HgssRuleset:handler(name)
  assert(type(name) == "string", "handler reads name their lifecycle phase")
  local bound = self._handlers[name]
  assert(type(bound) == "function", "handler reads name a bound lifecycle phase")
  return bound
end

---@return boolean
function HgssRuleset:finalize()
  assert(self._bound, "native rulesets release only after binding")
  assert(not self._finalized, "native rulesets release once")
  self._finalized = true
  return true
end

return HgssRuleset
