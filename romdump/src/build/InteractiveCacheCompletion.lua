-- Owns explicit complete-build and authorized background-sweep progress
-- for one interactive cache generation session.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")

---@class InteractiveCacheCompletion.Scope
---@field remaining integer enrolled members without a terminal state
---@field failed integer enrolled members with a terminal failure
---@field seen table<string, string> member identity to pending or settled
---@field failure string|nil first notified member failure when present

---@class InteractiveCacheCompletion
---@field session InteractiveCacheBuild|nil owning generation session, cleared on retirement
---@field completeUrgency string|nil retained explicit complete-build intent
---@field completeNext (fun(): { kind: string, key: string }|nil)|nil canonical complete enumerator once adopted
---@field completeExhausted boolean canonical complete enumeration reached its end
---@field completeScope InteractiveCacheCompletion.Scope cached complete-build terminal accounting
---@field sweepAuthorized boolean background corpus completion authorized through the lifecycle seam
---@field sweepNext (fun(): { kind: string, key: string }|nil)|nil retained canonical corpus enumerator
---@field sweepCandidate string|nil current sweep-origin candidate awaiting settlement
---@field sweepExhausted boolean canonical corpus enumeration reached its end
---@field sweepFailure string|nil first background candidate failure when present
local InteractiveCacheCompletion = {}
InteractiveCacheCompletion.__index = InteractiveCacheCompletion

local SWEEP_SETTLE_SECONDS = 1.0
local SWEEP_SETTLE_EPSILON = 1e-9

---@param session InteractiveCacheBuild
---@return InteractiveCacheCompletion
function InteractiveCacheCompletion.new(session)
  return setmetatable({
    session = session,
    completeUrgency = nil,
    completeNext = nil,
    completeExhausted = false,
    completeScope = { remaining = 0, failed = 0, seen = {}, failure = nil },
    sweepAuthorized = false,
    sweepNext = nil,
    sweepCandidate = nil,
    sweepExhausted = false,
    sweepFailure = nil,
  }, InteractiveCacheCompletion)
end

---@return boolean complete intent has been requested
function InteractiveCacheCompletion:completeRequested()
  return self.completeUrgency ~= nil
end

---@return string|nil retained complete urgency
function InteractiveCacheCompletion:requestedUrgency()
  return self.completeUrgency
end

---@return boolean background completion was authorized
function InteractiveCacheCompletion:sweepIsAuthorized()
  return self.sweepAuthorized
end

---@param urgency string
---@return boolean
---@return string|nil
function InteractiveCacheCompletion:requestComplete(urgency)
  local session = assert(self.session, "completion owner is retired")
  assert(not session.retired, "generation session is retired")
  ArtifactJobs.priorityFor(urgency)
  if
    self.completeUrgency == nil or ArtifactJobs.priorityFor(urgency) < ArtifactJobs.priorityFor(self.completeUrgency)
  then
    self.completeUrgency = urgency
  end
  return self:answer()
end

---@return boolean ready
---@return string|nil failure
function InteractiveCacheCompletion:answer()
  -- Retained observation only: an unrequested complete build is pending
  -- knowledge, never a vacuous success. No enumeration, IO or validation.
  if self.completeUrgency == nil then
    return false, nil
  end
  if self.completeScope.failure ~= nil then
    return false, self.completeScope.failure
  end
  if not self.completeExhausted or self.completeScope.remaining > 0 then
    return false, nil
  end
  return true, nil
end

---@param urgency string
---@return string urgency retained complete intent or the supplied sweep urgency
function InteractiveCacheCompletion:metadataUrgency(urgency)
  return self.completeUrgency or (self.sweepAuthorized and "sweep") or urgency
end

---@return boolean some retained demand can use source/page membership
function InteractiveCacheCompletion:needsMembership()
  return self.completeUrgency ~= nil or self.sweepAuthorized
end

-- Owner-only lifecycle authorization for opportunistic background corpus
-- completion. The call itself is O(1): it records authorization and
-- performs no enumeration, validation, filesystem IO, or submission.
function InteractiveCacheCompletion:enableSweep()
  local session = assert(self.session, "completion owner is retired")
  assert(not session.retired, "generation session is retired")
  self.sweepAuthorized = true
  session.lastForegroundActivity = session.clock()
end

---@return boolean a fresh sweep-origin candidate must wait out foreground quiet
function InteractiveCacheCompletion:_sweepQuietPending()
  local session = assert(self.session, "completion owner is retired")
  return session.clock() - session.lastForegroundActivity < SWEEP_SETTLE_SECONDS - SWEEP_SETTLE_EPSILON
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheCompletion:pump(budget)
  self:_expandComplete(budget)
  self:_advanceSweep(budget)
end

-- Explicit complete enrollment advances a small chunk per update through
-- the canonical producer enumerator, so entry work in the ticket queues
-- keeps progressing alongside it. Creating and advancing the enumerator
-- never builds, sorts, or copies the corpus: one logical job per
-- enumerator call enrolls under the budget with no worker payloads
-- allocated for the entire corpus at once.
---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheCompletion:_expandComplete(budget)
  local session = assert(self.session, "completion owner is retired")
  if self.completeUrgency == nil or self.completeExhausted then
    return
  end
  if not session.sourceLoaded or not session.pagesKnown then
    return
  end
  if self.completeNext == nil then
    if not session:_spendNode(budget) then
      return
    end
    self.completeNext =
      ArtifactJobs.completeIterator(assert(session.adopted, "complete enumeration needs its adopted inventory"))
  end
  local enrolled = 0
  while enrolled < 8 do
    local job = assert(self.completeNext, "complete enumeration owns its canonical enumerator")()
    if job == nil then
      self.completeExhausted = true
      self.completeNext = nil
      return
    end
    if not session:_spendNode(budget) then
      return
    end
    enrolled = enrolled + 1
    local entry = session:_register(job.kind, job.key, assert(self.completeUrgency, "complete intent owns its urgency"))
    self:_accountCompleteMember(entry)
  end
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheCompletion:_advanceSweep(budget)
  local session = assert(self.session, "completion owner is retired")
  -- Opportunistic background completion through the canonical graph: at
  -- most one sweep-origin corpus candidate advances at a time, only
  -- while no required or near work is outstanding, and never by
  -- materializing the whole corpus. Ready and failed records settle
  -- through the same registration path as explicit demand; a failed
  -- candidate keeps its attributed failure without failing unrelated
  -- scopes and the cursor moves on without retrying it.
  if session.retired or not self.sweepAuthorized or self.sweepExhausted then
    return
  end
  if session.foregroundPendingCount > 0 then
    return
  end
  local candidate = self.sweepCandidate ~= nil and session.byKey[self.sweepCandidate] or nil
  if candidate ~= nil then
    if candidate.failure ~= nil then
      if self.sweepFailure == nil then
        self.sweepFailure = candidate.failure
      end
      self.sweepCandidate = nil
    elseif candidate.ready then
      self.sweepCandidate = nil
    else
      return
    end
  end
  if not session.sourceLoaded or not session.pagesKnown then
    return
  end
  if self:_sweepQuietPending() then
    return
  end
  if self.sweepNext == nil then
    if not session:_spendNode(budget) then
      return
    end
    self.sweepNext =
      ArtifactJobs.completeIterator(assert(session.adopted, "background enumeration needs its adopted inventory"))
  end
  while true do
    if not session:_spendNode(budget) then
      return
    end
    local job = assert(self.sweepNext, "background enumeration owns its canonical iterator")()
    if job == nil then
      self.sweepExhausted = true
      self.sweepNext = nil
      return
    end
    local entry = session:_register(job.kind, job.key, "sweep")
    if entry.failure ~= nil then
      if self.sweepFailure == nil then
        self.sweepFailure = entry.failure
      end
    elseif not entry.ready then
      self.sweepCandidate = entry.jobKey
      return
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheCompletion:noteTerminal(entry)
  local complete = self.completeScope
  if complete.seen[entry.jobKey] ~= "pending" then
    return
  end
  complete.seen[entry.jobKey] = "settled"
  complete.remaining = complete.remaining - 1
  if entry.failure ~= nil then
    complete.failed = complete.failed + 1
    if complete.failure == nil then
      complete.failure = entry.failure
    end
  end
end

---@param entry InteractiveCacheBuild.Interest
function InteractiveCacheCompletion:_accountCompleteMember(entry)
  local complete = self.completeScope
  if complete.seen[entry.jobKey] ~= nil then
    return
  end
  if entry.failure ~= nil then
    complete.seen[entry.jobKey] = "settled"
    complete.failed = complete.failed + 1
    if complete.failure == nil then
      complete.failure = entry.failure
    end
  elseif entry.ready then
    complete.seen[entry.jobKey] = "settled"
  else
    complete.seen[entry.jobKey] = "pending"
    complete.remaining = complete.remaining + 1
  end
end

function InteractiveCacheCompletion:adopted()
  self.completeNext = nil
  self.completeExhausted = false
  self.sweepNext = nil
  self.sweepCandidate = nil
  self.sweepExhausted = false
end

---@return boolean unexpanded explicit complete demand can advance now
function InteractiveCacheCompletion:_completeExpansionReady()
  local session = assert(self.session, "completion owner is retired")
  return self.completeUrgency ~= nil and not self.completeExhausted and session.sourceLoaded and session.pagesKnown
end

---@return boolean unexpanded background completion can advance now
function InteractiveCacheCompletion:_sweepExpansionReady()
  local session = assert(self.session, "completion owner is retired")
  if not self.sweepAuthorized or self.sweepExhausted or not session.sourceLoaded or not session.pagesKnown then
    return false
  end
  if session.foregroundPendingCount > 0 then
    return false
  end
  local candidate = self.sweepCandidate ~= nil and session.byKey[self.sweepCandidate] or nil
  if candidate ~= nil then
    return candidate.ready or candidate.failure ~= nil
  end
  return not self:_sweepQuietPending()
end

---@return boolean unexpanded completion can advance now
function InteractiveCacheCompletion:hasRunnableExpansion()
  return self:_completeExpansionReady() or self:_sweepExpansionReady()
end

---@return number|nil seconds until local planning becomes retryable; nil when no clock-driven wake is needed
function InteractiveCacheCompletion:nextPlanningWakeDelay()
  local session = assert(self.session, "completion owner is retired")
  if session.retired or not self.sweepAuthorized or self.sweepExhausted then
    return nil
  end
  if not session.sourceLoaded or not session.pagesKnown then
    return nil
  end
  if session.foregroundPendingCount > 0 then
    return nil
  end
  local candidate = self.sweepCandidate ~= nil and session.byKey[self.sweepCandidate] or nil
  if candidate ~= nil or not self:_sweepQuietPending() then
    return nil
  end
  local remaining = session.lastForegroundActivity + SWEEP_SETTLE_SECONDS - session.clock()
  if remaining <= 0 then
    return 0
  end
  return remaining
end

---@return boolean no complete intent or complete enumeration exhausted
function InteractiveCacheCompletion:completeDone()
  return self.completeUrgency == nil or self.completeExhausted
end

---@return boolean complete enumeration was explicitly requested and exhausted
function InteractiveCacheCompletion:completeAttested()
  return self.completeUrgency ~= nil and self.completeExhausted
end

---@return { completeDone: boolean, completeAttested: boolean, completeExhausted: boolean, sweepState: string, sweepFailure: string|nil } completion status projection
function InteractiveCacheCompletion:status()
  local sweepState = "warming"
  if not self.sweepAuthorized then
    sweepState = "idle"
  elseif self.sweepExhausted then
    sweepState = self.sweepFailure == nil and "exhausted" or "incomplete"
  end
  return {
    completeDone = self:completeDone(),
    completeAttested = self:completeAttested(),
    completeExhausted = self.completeExhausted,
    sweepState = sweepState,
    sweepFailure = self.sweepFailure,
  }
end

function InteractiveCacheCompletion:retire()
  local session = self.session
  if session ~= nil and session.completion == self then
    session.completion = nil
  end
  self.session = nil
  self.completeUrgency = nil
  self.completeNext = nil
  self.completeExhausted = false
  self.completeScope = { remaining = 0, failed = 0, seen = {}, failure = nil }
  self.sweepAuthorized = false
  self.sweepNext = nil
  self.sweepCandidate = nil
  self.sweepExhausted = false
  self.sweepFailure = nil
end

return InteractiveCacheCompletion
