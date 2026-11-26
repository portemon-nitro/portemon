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
---@field sweepMembers table<string, "supply"|"observed"> sweep roots still without a terminal state, and whether the sweep admitted each as new supply
---@field sweepMemberCount integer sweep members still without a terminal state
---@field sweepSupplyCount integer outstanding roots this sweep admitted as independent supply
---@field sweepExhausted boolean canonical corpus enumeration reached its end
---@field sweepFailure string|nil first background candidate failure when present
local InteractiveCacheCompletion = {}
InteractiveCacheCompletion.__index = InteractiveCacheCompletion

local SWEEP_SETTLE_SECONDS = 1.0
local SWEEP_SETTLE_EPSILON = 1e-9
-- Candidates one pump may inspect while looking for independent sweep roots. A
-- candidate already enrolled from another origin supplies no additional
-- occupancy, so the pump steps past it instead of counting it as new supply
-- (it is still tracked as sweep membership); the bound keeps that lookahead a
-- few dozen entries rather than a corpus walk.
local SWEEP_LOOKAHEAD_CANDIDATES = 64
-- Canonical candidates the speculative pass may reorder by size class at once.
-- The window is what lets a later small job go before an earlier heavy one; a
-- corpus-sized sort would defeat the enumerator's incremental ownership.
local SWEEP_SIZE_LOOKAHEAD = 8

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
    sweepMembers = {},
    sweepMemberCount = 0,
    sweepSupplyCount = 0,
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

---@return integer sweep roots that may be outstanding at once
function InteractiveCacheCompletion:_sweepTarget()
  local session = assert(self.session, "completion owner is retired")
  if not session.loading then
    return 1
  end
  -- Ahead of the compiler pool: the root supply tracks the active occupancy the
  -- pool's current policy allows (not every thread it happens to retain from an
  -- earlier loader). It bounds concurrent sweep roots, not dependency-ready
  -- work: several roots behind one unfinished prerequisite can still leave a
  -- slot idle, which is a tuning question rather than a correctness one.
  return math.max(2, session.pool:occupancyLimit())
end

-- Record one sweep member. `supply` distinguishes the roots this sweep admitted
-- to keep the pool busy from a candidate another origin had already enrolled:
-- the latter feeds no new occupancy but is still this sweep's membership, so its
-- terminal fact settles here.
---@param jobKey string
---@param supply boolean
function InteractiveCacheCompletion:_trackSweepMember(jobKey, supply)
  local existing = self.sweepMembers[jobKey]
  if existing == nil then
    self.sweepMembers[jobKey] = supply and "supply" or "observed"
    self.sweepMemberCount = self.sweepMemberCount + 1
    if supply then
      self.sweepSupplyCount = self.sweepSupplyCount + 1
    end
    return
  end
  if supply and existing == "observed" then
    self.sweepMembers[jobKey] = "supply"
    self.sweepSupplyCount = self.sweepSupplyCount + 1
  end
end

-- Retire every sweep member that reached a terminal state. A failed member keeps
-- its attributed failure without failing unrelated scopes.
function InteractiveCacheCompletion:_settleSweepOutstanding()
  if self.sweepMemberCount == 0 then
    return
  end
  local session = assert(self.session, "completion owner is retired")
  for jobKey, kind in pairs(self.sweepMembers) do
    local entry = session.byKey[jobKey]
    if entry == nil or entry.ready or entry.failure ~= nil then
      self.sweepMembers[jobKey] = nil
      self.sweepMemberCount = self.sweepMemberCount - 1
      if kind == "supply" then
        self.sweepSupplyCount = self.sweepSupplyCount - 1
      end
      if entry ~= nil and entry.failure ~= nil and self.sweepFailure == nil then
        self.sweepFailure = entry.failure
      end
    end
  end
end

---@param budget InteractiveCacheBuild.Budget|nil
function InteractiveCacheCompletion:_advanceSweep(budget)
  local session = assert(self.session, "completion owner is retired")
  -- Opportunistic background completion through the canonical graph: an
  -- ordinary interactive session keeps exactly one sweep-origin corpus
  -- candidate in flight and only while no required or near work is
  -- outstanding, behind a foreground quiet window. A loader presentation owns
  -- the host instead: it keeps a bounded supply of independent roots ahead of
  -- the pool's free slots and skips the quiet window, so a root waiting on a
  -- dependency never blocks unrelated sweep work. Neither mode materializes
  -- the corpus: roots enroll through the same registration path as explicit
  -- demand, and a failed candidate keeps its attributed failure.
  --
  -- Cursor exhaustion is not sweep completion: enrolled roots keep settling
  -- after the enumerator ended, and a failure among them still belongs to this
  -- sweep. Terminal accounting therefore runs on every pump, including the one
  -- that observes the last root settle.
  if session.retired or not self.sweepAuthorized then
    return
  end
  self:_settleSweepOutstanding()
  if self.sweepExhausted and self.sweepMemberCount == 0 then
    return
  end
  if not session.loading then
    if session.foregroundPendingCount > 0 then
      return
    end
    if self:_sweepQuietPending() then
      return
    end
  end
  if not session.sourceLoaded or not session.pagesKnown then
    return
  end
  if self.sweepExhausted then
    return
  end
  if self.sweepNext == nil then
    if not session:_spendNode(budget) then
      return
    end
    self.sweepNext = ArtifactJobs.priorityIterator(
      assert(session.adopted, "background enumeration needs its adopted inventory"),
      SWEEP_SIZE_LOOKAHEAD
    )
  end
  local target = self:_sweepTarget()
  local inspected = 0
  while self.sweepSupplyCount < target and inspected < SWEEP_LOOKAHEAD_CANDIDATES do
    if not session:_spendNode(budget) then
      return
    end
    local job = assert(self.sweepNext, "background enumeration owns its canonical iterator")()
    if job == nil then
      self.sweepExhausted = true
      self.sweepNext = nil
      return
    end
    inspected = inspected + 1
    local jobKey = ArtifactJobs.jobKey(job.kind, job.key)
    local existing = session.byKey[jobKey]
    if existing == nil or existing.ready or existing.failure ~= nil then
      local entry = session:_register(job.kind, job.key, "sweep")
      if entry.failure ~= nil then
        if self.sweepFailure == nil then
          self.sweepFailure = entry.failure
        end
      elseif not entry.ready then
        self:_trackSweepMember(entry.jobKey, true)
      end
    elseif self.sweepMembers[jobKey] == nil then
      -- A candidate another origin already enrolled is the same physical job: it
      -- supplies no independent occupancy, but it is still this sweep's
      -- membership, so its terminal fact settles here.
      self:_trackSweepMember(jobKey, false)
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
  self.sweepMembers = {}
  self.sweepMemberCount = 0
  self.sweepSupplyCount = 0
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
  if not self.sweepAuthorized or not session.sourceLoaded or not session.pagesKnown then
    return false
  end
  self:_settleSweepOutstanding()
  if self.sweepExhausted or self.sweepSupplyCount >= self:_sweepTarget() then
    return false
  end
  if not session.loading then
    if session.foregroundPendingCount > 0 then
      return false
    end
    if self:_sweepQuietPending() then
      return false
    end
  end
  return true
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
  if session.loading then
    -- The loader has no quiet window to wait out; a pump is already owed
    -- whenever expansion is runnable and the pool reports its own waits.
    return nil
  end
  if not session.sourceLoaded or not session.pagesKnown then
    return nil
  end
  if session.foregroundPendingCount > 0 then
    return nil
  end
  self:_settleSweepOutstanding()
  if self.sweepMemberCount > 0 or not self:_sweepQuietPending() then
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

-- Read-only source-lifetime oracle for the compiler pool: true only when
-- no source-dependent work can still arrive from this owner. Pending
-- required/near interest, an open complete intent, an unsettled sweep
-- candidate, and an unexhausted authorized sweep each keep the shared
-- buffer alive; terminal failure still settles, since failed work is
-- accounted, not pending. A retired owner settles vacuously: retirement
-- already drops the buffer through its own barrier. The pool keeps its
-- own dispatch/publication/close checks; this answers only the sweep
-- side the pool cannot see.
---@return boolean no future source work can arrive from this owner
function InteractiveCacheCompletion:sourceWorkSettled()
  local session = self.session
  if session == nil or session.retired then
    return true
  end
  if session.foregroundPendingCount > 0 then
    return false
  end
  self:_settleSweepOutstanding()
  if self.sweepMemberCount > 0 then
    return false
  end
  if self.completeUrgency ~= nil then
    if not self.completeExhausted or self.completeScope.remaining > 0 then
      return false
    end
  end
  if self.sweepAuthorized and not self.sweepExhausted then
    return false
  end
  return true
end

---@return { completeDone: boolean, completeAttested: boolean, completeExhausted: boolean, sweepState: string, sweepFailure: string|nil } completion status projection
function InteractiveCacheCompletion:status()
  -- Read-only projection: settlement is only observed here, never advanced, so a
  -- status call cannot consume a terminal fact. Exhausted means the cursor and
  -- every enrolled root are done; while roots still settle the sweep is
  -- "settling" and no completion claim is made.
  local sweepState = "warming"
  if not self.sweepAuthorized then
    sweepState = "idle"
  elseif self.sweepExhausted and self.sweepMemberCount == 0 then
    sweepState = self.sweepFailure == nil and "exhausted" or "incomplete"
  elseif self.sweepExhausted then
    sweepState = "settling"
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
  self.sweepMembers = {}
  self.sweepMemberCount = 0
  self.sweepSupplyCount = 0
  self.sweepExhausted = false
  self.sweepFailure = nil
end

return InteractiveCacheCompletion
