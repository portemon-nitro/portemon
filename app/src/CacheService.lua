-- Process-owned transport to the single off-main cache controller. The
-- service owns channel identities, a bounded outbox, deduplicated semantic
-- observations, and epoch and barrier bookkeeping only. It mirrors no
-- dependency graph, performs no producer hashing, filesystem traversal,
-- publication, recovery, or source-plan parsing, and never waits on a
-- channel: requests return cached ready/error observations, terminal
-- request/barrier/failure facts arrive as pushed controller events, and
-- process shutdown alone joins the controller thread.

local ORDINARY_PER_UPDATE = 8
local ABSORB_PER_UPDATE = 32

local VALID_KINDS = {
  milestone = true,
  field = true,
  ["logical-field"] = true,
  cell = true,
  portrait = true,
  ["icon-page"] = true,
  ["battle-scene"] = true,
  ["audio-bank"] = true,
  pokedex = true,
}
local VALID_URGENCIES = { required = true, near = true, sweep = true }
local URGENCY_ORDER = { required = 0, near = 10, sweep = 100 }

---@class CacheService
---@field _threadHost table<string, function>
---@field _command table<string, function>
---@field _reply table<string, function>
---@field _worker table<string, unknown>?
---@field _started boolean
---@field _joined boolean
---@field _nextEpoch integer
---@field _liveEpoch integer?
---@field _retiring boolean
---@field _nextRequestId integer
---@field _nextBarrierId integer
---@field _records table<integer, table<string, unknown>> requestId -> record
---@field _byKey table<string, integer> epoch:key -> requestId
---@field _controls table<string, unknown>[] lifecycle commands awaiting emission
---@field _ordinary table<string, unknown>[] request/promote commands awaiting emission
---@field _barriers table<string, table<string, unknown>> "epoch:barrier" -> waiter
---@field _failure string? terminal controller failure, never restarted
---@field _generations table<integer, string> controller-derived generation token by epoch
---@field _sweepSent table<integer, boolean> epochs with queued warmup authorization
---@field _boot table<integer, table<string, unknown>> epoch-scoped boot-source observation
---@field _bootRequested table<integer, boolean> epochs with a queued boot gate
local CacheService = {}
CacheService.__index = CacheService

---@param options table<string, unknown>? { thread = love.thread-shaped host }
---@return CacheService
function CacheService.new(options)
  options = options or {}
  local host = options.thread
  if host == nil then
    local loveGlobal = rawget(_G, "love")
    host = loveGlobal and loveGlobal.thread
  end
  assert(
    type(host) == "table" and type(host.newChannel) == "function" and type(host.newThread) == "function",
    "cache service requires love.thread"
  )
  local command = assert(host.newChannel(), "cache service requires its command channel")
  local reply = assert(host.newChannel(), "cache service requires its reply channel")
  return setmetatable({
    _threadHost = host,
    _command = command,
    _reply = reply,
    _worker = nil,
    _started = false,
    _joined = false,
    _nextEpoch = 0,
    _liveEpoch = nil,
    _retiring = false,
    _nextRequestId = 0,
    _nextBarrierId = 0,
    _records = {},
    _byKey = {},
    _controls = {},
    _ordinary = {},
    _barriers = {},
    _generations = {},
    _failure = nil,
    _sweepSent = {},
    _boot = {},
    _bootRequested = {},
  }, CacheService)
end

---@param versionId unknown
local function checkVersion(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "cache selection requires a version")
end

---@param selector table<string, unknown>
---@return string dedup key for the semantic request
local function selectorKey(selector)
  assert(type(selector) == "table", "cache request requires its selectors")
  local kind = selector.requestKind
  assert(VALID_KINDS[kind], "unknown cache request kind: " .. tostring(kind))
  -- Observations may omit urgency: the dedup key never carries it, so a
  -- terminal event addresses the same record its request registered.
  local urgency = selector.urgency
  if urgency ~= nil then
    assert(VALID_URGENCIES[urgency], "unknown cache urgency: " .. tostring(urgency))
  end
  if kind == "milestone" then
    assert(type(selector.name) == "string" and selector.name ~= "", "milestone request requires its name")
    return "milestone:" .. selector.name
  elseif kind == "field" or kind == "logical-field" then
    assert(
      type(selector.mapId) == "number" and selector.mapId % 1 == 0 and selector.mapId >= 0,
      kind .. " request requires a non-negative integer mapId"
    )
    return kind .. ":" .. tostring(selector.mapId)
  elseif kind == "cell" then
    assert(
      type(selector.matrixMemberId) == "number" and selector.matrixMemberId % 1 == 0 and selector.matrixMemberId >= 0,
      "cell request requires a non-negative integer matrixMemberId"
    )
    assert(
      type(selector.index) == "number" and selector.index % 1 == 0 and selector.index >= 0,
      "cell request requires a non-negative integer index"
    )
    return "cell:" .. tostring(selector.matrixMemberId) .. ":" .. tostring(selector.index)
  elseif kind == "battle-scene" then
    assert(
      type(selector.sceneKey) == "string" and selector.sceneKey:match("^[^/]+/[^/]+/[^/]+$") ~= nil,
      "battle-scene request requires its background/terrain/time sceneKey"
    )
    return "battle-scene:" .. selector.sceneKey
  elseif kind == "audio-bank" then
    assert(
      type(selector.bankId) == "number" and selector.bankId % 1 == 0 and selector.bankId >= 0,
      "audio-bank request requires a non-negative integer bankId"
    )
    return "audio-bank:" .. tostring(selector.bankId)
  elseif kind == "pokedex" then
    assert(selector.pageId == nil, "pokedex request carries no page selector")
    assert(selector.name == nil, "pokedex request carries no milestone selector")
    assert(selector.mapId == nil, "pokedex request carries no map selector")
    assert(selector.matrixMemberId == nil, "pokedex request carries no cell selector")
    assert(selector.index == nil, "pokedex request carries no cell selector")
    assert(selector.sceneKey == nil, "pokedex request carries no scene selector")
    assert(selector.bankId == nil, "pokedex request carries no bank selector")
    return "pokedex"
  else
    assert(
      type(selector.pageId) == "number" and selector.pageId % 1 == 0 and selector.pageId >= 0,
      kind .. " request requires a non-negative integer pageId"
    )
    return kind .. ":" .. tostring(selector.pageId)
  end
end

---@param options table<string, unknown> { versionId, development?, repositoryRoot? }
---@return integer? epoch, nil when the controller cannot select
function CacheService:select(options)
  assert(type(options) == "table", "cache selection requires its selectors")
  checkVersion(options.versionId)
  if self._failure ~= nil then
    return nil
  end
  local host = self._threadHost
  if not self._started then
    local Worker = require("romdump.src.build.CacheControllerWorker")
    local bootstrap = assert(Worker.bootstrap(), "cache controller has no thread entry")
    local worker = host.newThread(bootstrap)
    local started, startError = pcall(function()
      worker:start(self._command, self._reply, package.path)
    end)
    if not started then
      self._failure = "controller thread failed to start: " .. tostring(startError)
      return nil
    end
    self._worker = worker
    self._started = true
  end
  self._nextEpoch = self._nextEpoch + 1
  local epoch = self._nextEpoch
  self._liveEpoch = epoch
  self._retiring = false
  local command = {
    op = "select",
    epoch = epoch,
    versionId = options.versionId,
    development = options.development == true,
  }
  if options.repositoryRoot ~= nil then
    assert(type(options.repositoryRoot) == "string", "cache repository root must be a string")
    command.repositoryRoot = options.repositoryRoot
  end
  self._controls[#self._controls + 1] = command
  self._boot[epoch] = { state = "pending" }
  self._bootRequested[epoch] = nil
  return epoch
end

-- Record (or strengthen) one semantic request. Only emission sends: repeats
-- for a pending record never queue another ensure command, and a
-- background-to-required strengthening queues a single promote for the
-- existing identity.
---@param epoch integer
---@param selector table<string, unknown>
---@return integer? request identity, nil for a stale epoch
function CacheService:request(epoch, selector)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  local key = selectorKey(selector)
  assert(VALID_URGENCIES[selector.urgency], "cache request requires its urgency")
  local mapKey = tostring(epoch) .. ":" .. key
  local existingId = self._byKey[mapKey]
  if existingId ~= nil then
    local record = assert(self._records[existingId], "cache request record is missing")
    if record.terminal then
      return existingId
    end
    local wanted = URGENCY_ORDER[selector.urgency]
    if wanted < URGENCY_ORDER[record.urgency] then
      record.urgency = selector.urgency
      if record.sent then
        self._ordinary[#self._ordinary + 1] =
          { op = "promote", epoch = epoch, requestId = existingId, urgency = "required" }
      else
        record.command.urgency = selector.urgency
      end
    end
    return existingId
  end
  self._nextRequestId = self._nextRequestId + 1
  local id = self._nextRequestId
  local command = {
    op = "request",
    epoch = epoch,
    requestId = id,
    requestKind = selector.requestKind,
    urgency = selector.urgency,
  }
  if selector.requestKind == "milestone" then
    command.name = selector.name
  elseif selector.requestKind == "field" or selector.requestKind == "logical-field" then
    command.mapId = selector.mapId
  elseif selector.requestKind == "cell" then
    command.matrixMemberId = selector.matrixMemberId
    command.index = selector.index
  elseif selector.requestKind == "battle-scene" then
    command.sceneKey = selector.sceneKey
  elseif selector.requestKind == "audio-bank" then
    command.bankId = selector.bankId
  elseif selector.requestKind == "pokedex" then
    -- The selector-free pokedex demand carries no job, source, page, or
    -- map identity: the dispatched packet names its kind and urgency only.
  else
    command.pageId = selector.pageId
  end
  self._records[id] = {
    id = id,
    epoch = epoch,
    key = key,
    selector = selector,
    urgency = selector.urgency,
    command = command,
    sent = false,
    terminal = false,
    ready = nil,
    failure = nil,
  }
  self._byKey[mapKey] = id
  self._ordinary[#self._ordinary + 1] = command
  return id
end

-- Cached observation only: never drains, sends, or waits. A retired epoch
-- grants no observation rights; a terminal controller failure reports its
-- cause instead of readiness.
---@param epoch integer
---@param selector table<string, unknown>
---@return boolean? ready
---@return string? failure
function CacheService:observe(epoch, selector)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil, nil
  end
  if self._failure ~= nil then
    return nil, self._failure
  end
  local key = selectorKey(selector)
  local id = self._byKey[tostring(epoch) .. ":" .. key]
  if id == nil then
    return nil, nil
  end
  local record = assert(self._records[id], "cache request record is missing")
  if record.terminal then
    if record.ready then
      return true, nil
    end
    return false, record.failure
  end
  return nil, nil
end

-- Cached controller-derived generation token for the epoch, or nil while
-- the selection answer is still in flight, the epoch is stale or retiring,
-- or the controller failed. Never scans, never waits: durability checks
-- treat an unknown generation as incomplete and prepare again.
---@param epoch integer
---@return string?
function CacheService:generationId(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  return self._generations[epoch]
end

-- Authorize lowest-priority background corpus completion for the epoch.
-- Idempotent per epoch: the controller authorization itself is idempotent
-- and performs no cache work in the call.
---@param epoch integer
function CacheService:enableSweep(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return
  end
  if self._failure ~= nil or self._sweepSent[epoch] then
    return
  end
  self._sweepSent[epoch] = true
  self._controls[#self._controls + 1] = { op = "enableSweep", epoch = epoch }
end

-- Retire the live epoch: observation rights end immediately while physical
-- retirement is acknowledged asynchronously through the exact barrier.
---@param epoch integer
---@return integer? barrier identity, nil for a stale epoch
function CacheService:retire(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  self._retiring = true
  self._generations[epoch] = nil
  self._boot[epoch] = nil
  self._bootRequested[epoch] = nil
  for position = #self._ordinary, 1, -1 do
    if self._ordinary[position].epoch == epoch then
      table.remove(self._ordinary, position)
    end
  end
  self._nextBarrierId = self._nextBarrierId + 1
  local barrier = self._nextBarrierId
  self._barriers[tostring(epoch) .. ":" .. tostring(barrier)] = { epoch = epoch, barrier = barrier, state = "pending" }
  self._controls[#self._controls + 1] = { op = "retire", epoch = epoch, barrierId = barrier }
  return barrier
end

-- Hand one validated immutable source buffer to the controller for the live
-- epoch. The game thread never opens the ROM itself: the import path
-- validated the bytes and the controller pins them to its selection. The
-- offer crosses by reference exactly once; stale, retired, or failed epochs
-- queue nothing, and a second offer for the same epoch is a programming
-- error only the caller can prevent.
---@param epoch integer selecting epoch, must be live
---@param byteData userdata the shared immutable buffer, passed by reference
---@param descriptor table<string, unknown> { versionId, romSha1 }
---@return boolean? true when the offer was queued, nil for a stale epoch
function CacheService:offerSource(epoch, byteData, descriptor)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  assert(type(byteData) == "userdata", "source handoff requires the shared buffer")
  assert(type(descriptor) == "table", "source handoff requires its version descriptor")
  assert(type(descriptor.versionId) == "string" and descriptor.versionId ~= "", "source handoff requires its version")
  assert(
    type(descriptor.romSha1) == "string" and #descriptor.romSha1 == 40,
    "source handoff requires its canonical identity"
  )
  self._controls[#self._controls + 1] = {
    op = "offer-source",
    epoch = epoch,
    byteData = byteData,
    versionId = descriptor.versionId,
    romSha1 = descriptor.romSha1,
  }
  return true
end

-- Queue the one boot-source gate behind selection and any source offer on
-- the same control FIFO. Idempotent for the live epoch: a duplicate call
-- registers nothing twice. Stale, retiring, or failed epochs queue nothing.
---@param epoch integer selecting epoch, must be live
---@return boolean? true when the gate is (or already was) queued, nil for a stale epoch
function CacheService:requestBootSource(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  if self._bootRequested[epoch] then
    return true
  end
  self._bootRequested[epoch] = true
  if self._boot[epoch] == nil then
    self._boot[epoch] = { state = "pending" }
  end
  self._controls[#self._controls + 1] = { op = "check-boot-source", epoch = epoch }
  return true
end

-- Cached boot-source observation only: never drains, sends, scans, or waits.
-- A retiring or stale epoch grants no observation rights; a terminal
-- controller failure reports its cause instead of readiness.
---@param epoch integer
---@return string? status "pending", "ready", "source-required", or "failed", nil for a stale epoch
---@return table<string, unknown>? detail typed { code, message, context? } cause on failure
function CacheService:bootSourceStatus(epoch)
  if type(epoch) ~= "number" or epoch ~= self._liveEpoch or self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return "failed", { code = "CONTROLLER_FAILED", message = self._failure }
  end
  local record = self._boot[epoch]
  if record == nil then
    return nil
  end
  return record.state, record.detail
end

-- Ask the controller to close every worker source context so a later source
-- replacement cannot race a live reader. Import waits for the exact
-- acknowledgement, never for an empty queue or a timeout.
---@param epoch integer
---@return integer? barrier identity, nil for a stale epoch
function CacheService:quiesce(epoch)
  if type(epoch) ~= "number" then
    return nil
  end
  if epoch ~= self._liveEpoch and not self._retiring then
    return nil
  end
  if self._failure ~= nil then
    return nil
  end
  self._nextBarrierId = self._nextBarrierId + 1
  local barrier = self._nextBarrierId
  self._barriers[tostring(epoch) .. ":" .. tostring(barrier)] =
    { epoch = epoch, barrier = barrier, state = "pending", quiesce = true }
  self._controls[#self._controls + 1] = { op = "quiesce", epoch = epoch, barrierId = barrier }
  return barrier
end

---@param epoch integer
---@param barrier integer
---@return string? "pending", "ready", "failed", or nil for an unknown barrier
function CacheService:barrierStatus(epoch, barrier)
  local waiter = self._barriers[tostring(epoch) .. ":" .. tostring(barrier)]
  if waiter == nil then
    return nil
  end
  if waiter.state == "ready" then
    return "ready"
  end
  if self._failure ~= nil then
    return "failed"
  end
  return "pending"
end

-- Authorize a source import behind an acknowledged quiescence barrier. The
-- acknowledgement is consumed exactly once: a second import needs a fresh
-- barrier.
---@param epoch integer
---@param barrier integer
---@return boolean ok
---@return string? refusal
function CacheService:importSource(epoch, barrier)
  local waiter = self._barriers[tostring(epoch) .. ":" .. tostring(barrier)]
  if waiter == nil or waiter.quiesce ~= true then
    return false, "no quiescence barrier authorizes the import"
  end
  if waiter.state ~= "ready" then
    return false, "no import crosses an unacknowledged quiescence barrier"
  end
  if waiter.consumed then
    return false, "the quiescence barrier authorized exactly one import"
  end
  waiter.consumed = true
  return true
end

-- Test-only transport injection: script a controller answer without a
-- thread. Production never calls this; it exists so composition tests can
-- drive barrier and readiness boundaries deterministically.
---@param packet table<string, unknown>
function CacheService:injectReply(packet)
  assert(type(packet) == "table", "injected reply must be a record")
  self._reply:push(packet)
end

---@param cause string?
function CacheService:_enterTerminalFailure(cause)
  if self._failure ~= nil then
    return
  end
  if cause == nil or cause == "" then
    cause = "controller thread exited"
  end
  self._failure = "controller thread stopped: " .. tostring(cause)
  self._controls = {}
  self._ordinary = {}
end

function CacheService:_checkWorkerHealth()
  if not self._started or self._joined or self._failure ~= nil then
    return
  end
  local worker = assert(self._worker, "cache controller thread is missing")
  if type(worker.isRunning) ~= "function" then
    return
  end
  local ok, running = pcall(function()
    return worker:isRunning()
  end)
  if ok and running then
    return
  end
  local cause = nil
  if not ok then
    cause = running
  elseif type(worker.getError) == "function" then
    local _, workerError = pcall(function()
      return worker:getError()
    end)
    cause = workerError
  end
  self:_enterTerminalFailure(cause)
end

---@param packet unknown
function CacheService:_absorb(packet)
  if type(packet) ~= "table" then
    return
  end
  local op = packet.op
  if op == "select-result" then
    self:_absorbSelectResult(packet)
  elseif op == "request-result" then
    self:_absorbRequestResult(packet)
  elseif op == "barrier-result" then
    self:_absorbBarrierResult(packet)
  elseif op == "boot-source-result" then
    self:_absorbBootSourceResult(packet)
  elseif op == "offer-source-result" then
    self:_absorbOfferSourceResult(packet)
  elseif op == "controller-failure" then
    self:_enterTerminalFailure(packet.errorMessage)
  end
end

-- A pushed terminal request fact lands only in its exact record: the
-- packet epoch must be live and the request identity must belong to it.
-- Stale or unknown results are ignored.
-- A pushed boot-gate fact lands only in its exact live record: the packet
-- epoch must be live and the boot observation still pending. A rejected
-- source offer already failed the epoch, so no later success can overwrite
-- it; duplicates and stale replies are ignored.
---@param packet table<string, unknown>
function CacheService:_absorbBootSourceResult(packet)
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  local record = self._boot[packet.epoch]
  if record == nil or record.state ~= "pending" then
    return
  end
  if packet.state == "ready" then
    record.state = "ready"
    record.detail = nil
  elseif packet.state == "source-required" or packet.state == "failed" then
    record.state = packet.state
    if type(packet.detail) == "table" then
      record.detail = packet.detail
    else
      record.detail = { code = "SOURCE_UNAVAILABLE", message = tostring(packet.detail) }
    end
  end
end

-- A pushed source-offer acknowledgement lands only in its exact live
-- record. Acceptance leaves the pending gate alone; a rejection fails the
-- epoch with its observable cause and no later gate answer can clear it.
---@param packet table<string, unknown>
function CacheService:_absorbOfferSourceResult(packet)
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  if packet.ok == true then
    return
  end
  local record = self._boot[packet.epoch]
  if record == nil or record.state ~= "pending" then
    return
  end
  local cause = packet.errorMessage
  if cause == nil or cause == "" then
    cause = "the controller refused the source offer"
  end
  record.state = "failed"
  record.detail = { code = "SOURCE_OFFER_REJECTED", message = tostring(cause) }
end

---@param packet table<string, unknown>
function CacheService:_absorbRequestResult(packet)
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  local record = self._records[packet.requestId]
  if record == nil or record.epoch ~= self._liveEpoch or record.terminal then
    return
  end
  if packet.state == "ready" then
    record.terminal = true
    record.ready = true
    record.failure = nil
  elseif packet.state == "failed" then
    record.terminal = true
    record.ready = false
    record.failure = packet.errorMessage or packet.errorCode
  end
end

-- A pushed barrier fact settles only its exact waiter: epoch, barrier
-- identity, and kind must all match. An older identity never satisfies a
-- newer waiter by ordering alone.
---@param packet table<string, unknown>
function CacheService:_absorbBarrierResult(packet)
  local waiter = self._barriers[tostring(packet.epoch) .. ":" .. tostring(packet.barrierId)]
  if waiter == nil or waiter.state ~= "pending" then
    return
  end
  if packet.kind == "quiesce" then
    if waiter.quiesce ~= true then
      return
    end
  elseif packet.kind == "retire" then
    if waiter.quiesce == true then
      return
    end
  else
    return
  end
  waiter.state = "ready"
  if packet.kind == "retire" and waiter.epoch == self._liveEpoch and self._retiring then
    self._liveEpoch = nil
    self._retiring = false
  end
end

---@param packet table<string, unknown>
function CacheService:_absorbSelectResult(packet)
  if packet.epoch ~= self._liveEpoch or self._retiring then
    return
  end
  if packet.ok ~= true then
    local message = packet.errorMessage
    if message == nil or message == "" then
      message = "controller selection failed"
    end
    self:_enterTerminalFailure(message)
    return
  end
  -- The controller-derived generation token is the canonical identity for
  -- durability decisions (first-play completion): it already reflects the
  -- ROM SHA, producer identity/mode, asset revision, and script API the
  -- game thread must never re-derive by scanning sources.
  if type(packet.generationId) == "string" and packet.generationId ~= "" then
    self._generations[packet.epoch] = packet.generationId
  end
end

---@return table<string, integer> emitted counts for the frame
function CacheService:_emit()
  local sent = { ordinary = 0 }
  for _, command in ipairs(self._controls) do
    self._command:push(command)
  end
  self._controls = {}
  for _, command in ipairs(self._ordinary) do
    if sent.ordinary >= ORDINARY_PER_UPDATE then
      break
    end
    self._command:push(command)
    local record = self._records[command.requestId]
    if record ~= nil then
      record.sent = true
    end
    sent.ordinary = sent.ordinary + 1
  end
  if sent.ordinary >= #self._ordinary then
    self._ordinary = {}
  else
    local waiting = {}
    for position = sent.ordinary + 1, #self._ordinary do
      waiting[#waiting + 1] = self._ordinary[position]
    end
    self._ordinary = waiting
  end
  return sent
end

-- Pump the transport once: absorb a bounded batch of pushed terminal
-- events, then emit at most eight queued ordinary records. Never blocks,
-- never performs producer or filesystem work.
---@return table<string, integer> emitted counts for the frame
function CacheService:update()
  self:_checkWorkerHealth()
  local absorbed = 0
  while absorbed < ABSORB_PER_UPDATE do
    local packet = self._reply:pop()
    if packet == nil then
      break
    end
    absorbed = absorbed + 1
    self:_absorb(packet)
  end
  if self._failure ~= nil then
    return { ordinary = 0 }
  end
  return self:_emit()
end

-- Join the controller thread exactly once. Process shutdown alone joins;
-- selection retirement never does. Unsent interest is discarded: shutdown
-- is final and nothing after it can observe this process.
function CacheService:shutdown()
  if self._joined then
    return
  end
  self._joined = true
  self._controls = {}
  self._ordinary = {}
  if not self._started then
    return
  end
  pcall(function()
    self._command:push({ op = "shutdown" })
  end)
  local worker = self._worker
  if worker ~= nil and type(worker.wait) == "function" then
    pcall(function()
      worker:wait()
    end)
  end
end

return CacheService
