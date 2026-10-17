-- Native post-battle evolution presentation state. Owns the source entry,
-- old/new picture animation, palette/visual effects, music/cry, progress
-- messages, permitted cancel, successful transformation, and subsequent
-- move-learning offers sequencing for one committed subject. Eligibility
-- and transformation stay with the evolution domain: candidates come from
-- Evolution.candidates in source order and each selected candidate stages
-- through Evolution.apply, so all returned mons and consumption publish as
-- one staged operation. The state never publishes: the staged records ride
-- the completion command. Effect records (music, cry, messages, palette)
-- are sequenced here as evidence for the audio/visual owners; text and
-- picture resolution stays with the normalized asset producers.
--
-- Only source-permitted input can cancel: confirmation and cancellation
-- act in the prompt phase under the current candidate's cancel policy, and
-- every other phase, key release, focus loss, and teardown decide nothing.

local Evolution = require("libs.mons.src.gen4.Evolution")

---@class BattleEvolutionState
---@field _plans table<integer, table<string, unknown>> staged candidate plans in source order
---@field _index integer current candidate position (1-based)
---@field _phase string current presentation phase
---@field _clock integer ticks spent in the current phase
---@field _effects table<integer, table<string, unknown>> sequenced effect requests in order
---@field _outcomes table<integer, table<string, unknown>> settled candidate outcomes in order
---@field _result table<string, unknown>? settled choice record
---@field _taken boolean result consumed
---@field _disposed boolean
local BattleEvolutionState = {}
BattleEvolutionState.__index = BattleEvolutionState

BattleEvolutionState.ENTRY_TICKS = 2
BattleEvolutionState.SEQUENCE_TICKS = 4
BattleEvolutionState.TRANSFORMATION_TICKS = 2

---@param candidate table<string, unknown> staged candidate plan under recording
---@param evolved boolean transformation applied under recording
---@param reason string? decline reason under recording
---@param staged table<string, unknown>? staged domain result under recording
---@return table<string, unknown> settled candidate outcome
local function recordOutcome(candidate, evolved, reason, staged)
  assert(type(candidate) == "table", "outcomes settle staged candidates")
  local outcome = {
    ruleIndex = candidate.ruleIndex,
    method = candidate.method,
    evolved = evolved,
  }
  if reason ~= nil then
    outcome.reason = reason
  end
  if staged ~= nil then
    outcome.staged = staged
  end
  return outcome
end

---@param opts { mon: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown> }
---@return BattleEvolutionState
function BattleEvolutionState.new(opts)
  assert(type(opts) == "table", "evolution presentation requires options")
  assert(type(opts.mon) == "table", "evolution presents its committed subject")
  assert(type(opts.context) == "table", "evolution presents its trigger context")
  assert(opts.catalog ~= nil, "evolution presents through its mon catalog")
  local candidates = Evolution.candidates(opts.mon, opts.context, opts.catalog)
  assert(type(candidates) == "table", "evolution eligibility answers its candidates")
  local plans = {}
  for position, candidate in ipairs(candidates) do
    assert(type(candidate) == "table", "evolution candidates arrive as records")
    local staged = Evolution.apply(opts.mon, candidate, opts.context, opts.catalog)
    assert(type(staged) == "table", "selected candidates stage their result")
    plans[position] = {
      ruleIndex = candidate.ruleIndex,
      method = candidate.method,
      target = candidate.target,
      form = candidate.form,
      canCancel = staged.canCancel,
      staged = staged,
    }
  end
  local self = setmetatable({
    _plans = plans,
    _index = 1,
    _phase = "entry",
    _clock = 0,
    _effects = {},
    _outcomes = {},
    _result = nil,
    _taken = false,
    _disposed = false,
  }, BattleEvolutionState)
  if #plans == 0 then
    self:_settle()
  else
    self:_record({ kind = "music", phase = "entry" })
  end
  return self
end

-- Records one sequenced effect request for the audio/visual owners. The
-- sequence owns order and timing; emission belongs to production.
---@param effect table<string, unknown> effect request under sequencing
function BattleEvolutionState:_record(effect)
  self._effects[#self._effects + 1] = effect
end

---@return table<string, unknown>? current candidate plan, nil once settled
function BattleEvolutionState:_current()
  return self._plans[self._index]
end

-- Advances past the current candidate: a confirmed candidate carries its
-- staged domain result, a permitted cancellation carries its reason, and
-- the next candidate enters while candidates remain. The final advance
-- settles the complete outcome list in source order.
---@param evolved boolean transformation applied under advancing
---@param reason string? decline reason under advancing
function BattleEvolutionState:_advance(evolved, reason)
  local current = assert(self:_current(), "advances settle their candidate")
  if evolved then
    self._outcomes[#self._outcomes + 1] = recordOutcome(current, true, nil, current.staged)
    self:_record({ kind = "palette", phase = "transformation", ruleIndex = current.ruleIndex })
  else
    local declined = recordOutcome(current, false, assert(reason, "declines name their reason"), nil)
    self._outcomes[#self._outcomes + 1] = declined
  end
  self._index = self._index + 1
  self._clock = 0
  if self._plans[self._index] == nil then
    self:_settle()
  else
    self._phase = "entry"
    self:_record({ kind = "music", phase = "entry" })
  end
end

-- Settles the complete evolution choice: every candidate outcome in
-- source order with its staged domain result or decline reason, and one
-- evolved flag for the whole sequence.
function BattleEvolutionState:_settle()
  local evolved = false
  for _, outcome in ipairs(self._outcomes) do
    if outcome.evolved == true then
      evolved = true
    end
  end
  if #self._plans == 0 then
    self._result =
      { kind = "choice", choice = { kind = "evolution", evolved = false, reason = "ineligible", outcomes = {} } }
  else
    local outcomes = {}
    for _, outcome in ipairs(self._outcomes) do
      outcomes[#outcomes + 1] = outcome
    end
    self._result = { kind = "choice", choice = { kind = "evolution", evolved = evolved, outcomes = outcomes } }
    if evolved then
      self:_record({ kind = "message", phase = "settled", id = "evolved" })
    else
      self:_record({ kind = "message", phase = "settled", id = "cancelled" })
    end
  end
  self._phase = "settled"
  self._clock = 0
end

---@param events table<integer, table<string, unknown>> semantic input batch under routing
function BattleEvolutionState:input(events)
  if self._disposed or self._result ~= nil or self._phase ~= "prompt" then
    return
  end
  assert(type(events) == "table", "evolution input arrives as an event list")
  for _, event in ipairs(events) do
    if self._result ~= nil or self._phase ~= "prompt" then
      break
    end
    if type(event) ~= "table" or type(event.type) ~= "string" then
      break
    end
    local current = self:_current()
    if current == nil then
      break
    end
    if event.type == "confirm" then
      -- Confirmation starts the transformation beat; the staged outcome
      -- records when the beat completes so a second confirmation inside
      -- the beat cannot apply twice.
      self._phase = "transformation"
      self._clock = 0
    elseif event.type == "cancel" then
      if current.canCancel == true then
        self:_advance(false, "cancelled")
      end
    end
  end
end

-- Advances the native sequence clock: entry runs its music beat, the
-- sequence runs the old-picture animation with its cry and progress
-- message, and the transformation beat holds after a confirmation. The
-- prompt waits for source-permitted input and never advances on ticks.
---@param ticks integer? source ticks under stepping, one when omitted
function BattleEvolutionState:stepSourceTick(ticks)
  if self._disposed or self._result ~= nil then
    return
  end
  local count = ticks or 1
  assert(type(count) == "number" and count % 1 == 0 and count >= 0, "evolution ticks stay non-negative integers")
  for _ = 1, count do
    if self._result ~= nil then
      break
    end
    self._clock = self._clock + 1
    if self._phase == "entry" and self._clock >= BattleEvolutionState.ENTRY_TICKS then
      local current = assert(self:_current(), "entry sequences its candidate")
      self._phase = "sequence"
      self._clock = 0
      self:_record({ kind = "cry", phase = "sequence", ruleIndex = current.ruleIndex })
      self:_record({ kind = "message", phase = "sequence", id = "evolving", ruleIndex = current.ruleIndex })
    elseif self._phase == "sequence" and self._clock >= BattleEvolutionState.SEQUENCE_TICKS then
      local current = assert(self:_current(), "prompts offer their candidate")
      self._phase = "prompt"
      self._clock = 0
      self:_record({ kind = "message", phase = "prompt", id = "prompt", canCancel = current.canCancel })
    elseif self._phase == "transformation" and self._clock >= BattleEvolutionState.TRANSFORMATION_TICKS then
      self:_advance(true)
    end
  end
end

---@return table<string, unknown> drawable evolution record (renderer-agnostic data)
function BattleEvolutionState:draw()
  local current = self:_current()
  return {
    kind = "evolution",
    phase = self._phase,
    ruleIndex = current ~= nil and current.ruleIndex or nil,
    candidates = #self._plans,
    settled = #self._outcomes,
    clock = self._clock,
  }
end

---@return table<string, unknown> evolution presentation status
function BattleEvolutionState:status()
  local current = self:_current()
  return {
    active = not self._disposed and self._result == nil,
    kind = "evolution",
    phase = self._phase,
    candidateIndex = self._index,
    candidateCount = #self._plans,
    canCancel = current ~= nil and current.canCancel or nil,
    effects = #self._effects,
  }
end

---@return table<integer, table<string, unknown>> sequenced effect requests in order (read-only evidence)
function BattleEvolutionState:effects()
  local out = {}
  for _, effect in ipairs(self._effects) do
    local record = {}
    for key, value in pairs(effect) do
      record[key] = value
    end
    out[#out + 1] = record
  end
  return out
end

---@return table<string, unknown>? settled evolution choice, exactly once
function BattleEvolutionState:takeResult()
  if self._disposed or self._result == nil or self._taken then
    return nil
  end
  self._taken = true
  return self._result
end

-- Idempotent release of the presentation lifetime: a settled result never
-- reports after disposal, and an unsettled sequence simply ends
-- unsettled without publishing anything.
function BattleEvolutionState:dispose()
  self._disposed = true
end

return BattleEvolutionState
