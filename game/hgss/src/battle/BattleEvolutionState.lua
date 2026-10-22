-- Native post-battle evolution presentation state. Owns the source entry,
-- old/new picture animation, palette/visual effects, music/cry, progress
-- messages, permitted cancel, successful transformation, and subsequent
-- move-learning offers sequencing for one committed subject. Eligibility,
-- planning, and transformation stay with the evolution domain: the state
-- binds exactly one EvolutionFlow, which selects the first matching
-- source rule, so all returned mons and consumption publish as one staged
-- operation. The state never publishes: the staged records ride the
-- completion command. Effect records (music, cry, messages, palette)
-- are sequenced here as evidence for the audio/visual owners; text and
-- picture resolution stays with the normalized asset producers.
--
-- The sequence starts on its own: entry runs its music beat, the old
-- picture animates with its cry, and the transformation beat follows
-- without any confirmation gate. Only source-permitted input can cancel:
-- cancellation acts during the entry, animation, and transformation
-- beats under the staged rule's cancel policy, and every other phase,
-- key release, focus loss, and teardown decide nothing. Once the
-- transformation completes the choice is accepted and each pending
-- learned move pauses for an explicit replace-or-decline answer.

local EvolutionFlow = require("libs.hgss.src.mons.EvolutionFlow")

---@class BattleEvolutionState
---@field _flow table<string, unknown>? single staged domain flow, nil while ineligible
---@field _canCancel boolean source cancel policy of the staged rule
---@field _accepted boolean true once the transformation completed and the choice is accepted
---@field _phase string current presentation phase
---@field _clock integer ticks spent in the current phase
---@field _prompt table<string, unknown>? pending learned-move prompt under answering
---@field _effects table<integer, table<string, unknown>> sequenced effect requests in order
---@field _result table<string, unknown>? settled choice record
---@field _taken boolean result consumed
---@field _disposed boolean
local BattleEvolutionState = {}
BattleEvolutionState.__index = BattleEvolutionState

BattleEvolutionState.ENTRY_TICKS = 2
BattleEvolutionState.SEQUENCE_TICKS = 4
BattleEvolutionState.TRANSFORMATION_TICKS = 2

---@param value unknown
---@return unknown detached copy without shared mutable state
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

---@param opts { mon: table<string, unknown>, context: table<string, unknown>, catalog: table<string, unknown> }
---@return BattleEvolutionState
function BattleEvolutionState.new(opts)
  assert(type(opts) == "table", "evolution presentation requires options")
  assert(type(opts.mon) == "table", "evolution presents its committed subject")
  assert(type(opts.context) == "table", "evolution presents its trigger context")
  assert(opts.catalog ~= nil, "evolution presents through its mon catalog")
  local flow = EvolutionFlow.start(copyValue(opts.mon), opts.context, opts.catalog)
  local self = setmetatable({
    _flow = flow,
    _canCancel = false,
    _accepted = false,
    _phase = "entry",
    _clock = 0,
    _prompt = nil,
    _effects = {},
    _result = nil,
    _taken = false,
    _disposed = false,
  }, BattleEvolutionState)
  if flow == nil then
    self:_settle({ kind = "choice", choice = { kind = "evolution", evolved = false, reason = "ineligible" } })
    return self
  end
  -- The opening domain prompt names the staged rule's cancel policy
  -- through the public step surface; the state never answers it here.
  local opening = EvolutionFlow.step(flow)
  assert(opening.prompt == "confirm_evolution", "the staged flow opens on its confirmation")
  self._canCancel = opening.canCancel == true
  self:_record({ kind = "music", phase = "entry" })
  return self
end

-- Records one sequenced effect request for the audio/visual owners. The
-- sequence owns order and timing; emission belongs to production.
---@param effect table<string, unknown> effect request under sequencing
function BattleEvolutionState:_record(effect)
  self._effects[#self._effects + 1] = effect
end

-- Settles the complete evolution choice exactly once.
---@param result table<string, unknown> settled choice record under latching
function BattleEvolutionState:_settle(result)
  if self._result ~= nil then
    return
  end
  self._result = result
  self._phase = "settled"
  self._clock = 0
  self._prompt = nil
end

-- Walks the accepted flow to its next pause: one pending learned move or
-- the terminal descriptor. Free move slots fill silently inside the
-- domain step; the settled capture carries the whole staged result.
function BattleEvolutionState:_walkAccepted()
  local flow = assert(self._flow, "accepted walks read their staged flow")
  local prompt = EvolutionFlow.step(flow)
  assert(type(prompt) == "table" and type(prompt.prompt) == "string", "accepted flows answer their prompt")
  if prompt.prompt == "learn_move" then
    self._phase = "learn"
    self._clock = 0
    self._prompt = copyValue(prompt)
    self:_record({ kind = "message", phase = "learn", id = "learn_move", move = prompt.move })
    return
  end
  assert(prompt.prompt == "complete", "accepted flows end on their terminal descriptor")
  local captured = EvolutionFlow.capture(flow)
  assert(type(captured) == "table", "completed flows capture their staged result")
  self:_record({ kind = "message", phase = "settled", id = "evolved" })
  self:_settle({
    kind = "choice",
    choice = {
      kind = "evolution",
      evolved = true,
      staged = {
        mon = captured.mon,
        additionalMons = captured.additionalMons or {},
        inventoryDeltas = captured.inventoryDeltas or {},
      },
    },
  })
end

-- Cancels the unaccepted sequence under the source policy: the domain
-- stages nothing and the choice names its cancellation.
---@param reason string decline reason under settling
function BattleEvolutionState:_cancel(reason)
  local flow = assert(self._flow, "cancels answer their staged flow")
  assert(not self._accepted, "cancels decide before the transformation completes")
  assert(self._canCancel, "cancels honor the source policy")
  EvolutionFlow.respond(flow, { choice = "cancel" })
  self:_record({ kind = "message", phase = "settled", id = "cancelled" })
  self:_settle({ kind = "choice", choice = { kind = "evolution", evolved = false, reason = reason } })
end

---@param events table<integer, table<string, unknown>> semantic input batch under routing
function BattleEvolutionState:input(events)
  if self._disposed or self._result ~= nil or self._accepted then
    return
  end
  if self._flow == nil then
    return
  end
  assert(type(events) == "table", "evolution input arrives as an event list")
  for _, event in ipairs(events) do
    if self._result ~= nil or self._accepted then
      break
    end
    if type(event) ~= "table" or type(event.type) ~= "string" then
      break
    end
    -- Confirmation never gates the sequence: the beats start on their
    -- own and only the permitted cancel edge decides anything.
    if event.type == "cancel" then
      if self._canCancel then
        self:_cancel("cancelled")
      end
    end
  end
end

-- Advances the native sequence clock: entry runs its music beat, the
-- sequence runs the old-picture animation with its cry and progress
-- message, and the transformation beat holds on its own. Completing the
-- transformation accepts the staged choice and walks into learning or
-- settlement; the learning pause waits for an explicit answer and never
-- advances on ticks.
---@param ticks integer? source ticks under stepping, one when omitted
function BattleEvolutionState:stepSourceTick(ticks)
  if self._disposed or self._result ~= nil then
    return
  end
  if self._flow == nil then
    return
  end
  local count = ticks or 1
  assert(type(count) == "number" and count % 1 == 0 and count >= 0, "evolution ticks stay non-negative integers")
  for _ = 1, count do
    if self._result ~= nil or self._phase == "learn" then
      break
    end
    self._clock = self._clock + 1
    if self._phase == "entry" and self._clock >= BattleEvolutionState.ENTRY_TICKS then
      self._phase = "sequence"
      self._clock = 0
      self:_record({ kind = "cry", phase = "sequence" })
      self:_record({ kind = "message", phase = "sequence", id = "evolving" })
    elseif self._phase == "sequence" and self._clock >= BattleEvolutionState.SEQUENCE_TICKS then
      self._phase = "transformation"
      self._clock = 0
    elseif self._phase == "transformation" and self._clock >= BattleEvolutionState.TRANSFORMATION_TICKS then
      local flow = assert(self._flow, "transformations accept their staged flow")
      EvolutionFlow.respond(flow, { choice = "accept" })
      self._accepted = true
      self:_record({ kind = "palette", phase = "transformation" })
      self:_walkAccepted()
    end
  end
end

-- Answers the pending learned move: replace names the held zero-based
-- slot taking the incoming move, decline keeps the held set. Either
-- answer advances to the next pending move or settles the sequence.
---@param reply { choice: string, slot: integer? } replace-or-decline answer under applying
function BattleEvolutionState:answerLearn(reply)
  assert(not self._disposed, "answers read a live sequence")
  assert(self._result == nil, "answers decide before settlement")
  assert(self._phase == "learn" and self._prompt ~= nil, "learning answers name the open prompt")
  assert(type(reply) == "table", "learning answers arrive as a record")
  local flow = assert(self._flow, "learning answers read their staged flow")
  if reply.choice == "decline" then
    EvolutionFlow.respond(flow, { choice = "decline" })
  elseif reply.choice == "replace" then
    assert(
      type(reply.slot) == "number" and reply.slot % 1 == 0 and reply.slot >= 0,
      "replacements name a held zero-based move slot"
    )
    EvolutionFlow.respond(flow, { choice = "replace", slot = reply.slot })
  else
    error("learning replies decline or replace the incoming move", 0)
  end
  self._prompt = nil
  self:_walkAccepted()
end

---@return table<string, unknown>? pending learned-move prompt, nil outside the learning pause
function BattleEvolutionState:learnPrompt()
  if self._prompt == nil then
    return nil
  end
  return copyValue(self._prompt)
end

---@return table<string, unknown> drawable evolution record (renderer-agnostic data)
function BattleEvolutionState:draw()
  return {
    kind = "evolution",
    phase = self._phase,
    clock = self._clock,
    learnPrompt = self:learnPrompt(),
  }
end

---@return table<string, unknown> evolution presentation status
function BattleEvolutionState:status()
  return {
    active = not self._disposed and self._result == nil,
    kind = "evolution",
    phase = self._phase,
    canCancel = self._flow ~= nil and self._canCancel or nil,
    learnPending = self._prompt ~= nil,
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
