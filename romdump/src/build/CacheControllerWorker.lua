-- Owns the interactive cache system off the game thread: one controller
-- thread per process drives generation selection, the demand/background
-- session graph (including the retained background completion cursor),
-- compiler worker dispatch, serialized publication/recovery, retirement and
-- source-close barriers, and orderly shutdown. The game thread sees only
-- pushed terminal request/barrier/failure facts through its service proxy
-- and never blocks for cache production. Batch preparation stays a separate
-- synchronous client of the same build modules.
--
-- Threading contract (official LOVE semantics): worker Lua states are
-- separate; this module loads love.thread/love.timer/love.system
-- explicitly in the worker. Worker states resolve thread sources as
-- filenames only, so compiler workers boot from FileData when the
-- code-string bootstrap is rejected there. No graphics, window, input, or
-- audio calls occur below this entry.

local InteractiveCacheBuild = require("romdump.src.build.InteractiveCacheBuild")
local CompilerPool = require("romdump.src.build.CompilerPool")
local DerivedCacheState = require("romdump.src.DerivedCacheState")
local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
local GameVersion = require("romdump.src.source.GameVersion")
local ProducerFingerprint = require("romdump.src.ProducerFingerprint")

local CacheControllerWorker = {}

-- Bounded wait cadence while progress depends on an external compiler or
-- source-close result. Those completions arrive on the pool's private
-- result channel, invisible to the control channel the worker blocks on,
-- so a waiting session polls on a short sleep-dominated tick rather than
-- blocking indefinitely. A fully idle controller (no selected session, or
-- a selected session with no runnable planning and no outstanding
-- worker/close result) blocks on the control channel with no timeout.
-- This is a static conservative cadence, not a frame governor: it never
-- inspects frame timing.
local LIVE_TICK_SECONDS = 0.005

-- Per-flush semantic observation work: one terminal-request sweep
-- re-observes at most this many pending application requests, so a large
-- retained set cannot turn a controller step into an unbounded scan.
local REQUEST_OBSERVATIONS_PER_STEP = 16

-- Fallback sleep when no LOVE timer is present. Named (not inline
-- anonymous) per repository source policy; run's fallback semantics
-- are unchanged.
---@param _ number ignored sleep duration
local function idleSleep(_) end

-- Single-shot code bootstrap for love.thread.newThread on the game thread.
-- Code strings boot on the game thread; the development search path is
-- installed explicitly because worker states do not inherit it. Packaged
-- builds resolve requires from the source archive with an empty path.
local function bootstrapSource()
  return [[
local controlChannel, replyChannel, developmentPath = ...
if type(developmentPath) == "string" and developmentPath ~= "" then
  package.path = developmentPath
end
pcall(require, "love.thread")
pcall(require, "love.timer")
pcall(require, "love.system")
local Worker = require("romdump.src.build.CacheControllerWorker")
Worker.run(controlChannel, replyChannel)
]]
end

---@return string code bootstrap for the controller thread entry
function CacheControllerWorker.bootstrap()
  return bootstrapSource()
end

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
  ["battle-effect"] = true,
  ["battle-presentation"] = true,
  ["startup-walker"] = true,
  ["opening-scene"] = true,
}
local VALID_URGENCIES = { required = true, near = true, sweep = true }

---@class CacheControllerSelection
---@field epoch integer
---@field versionId string
---@field development boolean
---@field repositoryRoot string?

local Worker = {}
Worker.__index = Worker

---@param control table<string, function>|userdata command channel (game thread pushes)
---@param reply table<string, function>|userdata reply channel (game thread pops)
---@return table<string, unknown> controller state (test-driving uses step)
function Worker.new(control, reply)
  assert(type(control) == "table" or type(control) == "userdata", "controller requires its command channel")
  assert(type(reply) == "table" or type(reply) == "userdata", "controller requires its reply channel")
  assert(type(control.pop) == "function", "controller command channel needs pop")
  assert(type(reply.push) == "function", "controller reply channel needs push")
  return setmetatable({
    control = control,
    reply = reply,
    pool = nil,
    poolRoot = false,
    session = nil,
    selectedVersionId = nil,
    selectedRomSha1 = nil,
    liveEpoch = nil,
    lastRetiredEpoch = nil,
    lifecycle = "starting",
    lifecycleError = nil,
    frozenProducerRoot = nil,
    frozenProducerId = nil,
    requests = {},
    pendingRequestIds = {},
    pendingRequestCursor = 1,
    deferredSelect = nil,
    pendingQuiesce = nil,
    exiting = false,
    maintenanceNote = nil,
    selectedIdentity = nil,
    offerError = nil,
    attestedFor = nil,
    attestationNote = nil,
  }, Worker)
end

---@param message string
function Worker:_fail(message)
  if self.lifecycle == "failed" then
    return
  end
  self.lifecycle = "failed"
  self.lifecycleError = message
  self.pendingQuiesce = nil
  self.deferredSelect = nil
  self.reply:push({ op = "controller-failure", errorMessage = message })
end

---@param epoch integer
---@param requestId integer
---@param observation table<string, unknown> terminal ready/failed observation
function Worker:_emitRequestResult(epoch, requestId, observation)
  local packet = { op = "request-result", epoch = epoch, requestId = requestId, state = observation.state }
  if observation.state == "failed" then
    packet.errorMessage = observation.errorMessage or ""
    packet.errorCode = observation.errorCode or ""
  end
  self.reply:push(packet)
end

---@param epoch integer
---@param barrierId integer
---@param kind string "retire" or "quiesce"
function Worker:_emitBarrierResult(epoch, barrierId, kind)
  self.reply:push({ op = "barrier-result", epoch = epoch, barrierId = barrierId, kind = kind })
end

-- Dense pending-request worklist: the request map stays the identity
-- owner while this sequence plus cursor retains fair traversal order
-- across flushes. Each record carries its sequence slot so removal is a
-- single swap with the last entry.
---@param worker table<string, unknown> controller state owning the request map and pending sequence
---@param requestId integer application request identity to track
local function trackPendingRequest(worker, requestId)
  local record = worker.requests[requestId]
  assert(record ~= nil, "controller tracks only retained requests")
  if record.pendingIndex ~= nil then
    return
  end
  local pendingIds = worker.pendingRequestIds
  pendingIds[#pendingIds + 1] = requestId
  record.pendingIndex = #pendingIds
end

---@param worker table<string, unknown> controller state owning the request map and pending sequence
---@param requestId integer application request identity to drop
local function dropPendingRequest(worker, requestId)
  local record = worker.requests[requestId]
  if record == nil then
    return
  end
  local pendingIds = worker.pendingRequestIds
  local index = record.pendingIndex
  worker.requests[requestId] = nil
  record.pendingIndex = nil
  if index == nil then
    return
  end
  assert(pendingIds[index] == requestId, "pending slot matches its record")
  local lastId = pendingIds[#pendingIds]
  pendingIds[index] = lastId
  pendingIds[#pendingIds] = nil
  if lastId ~= requestId then
    local moved = worker.requests[lastId]
    assert(moved ~= nil, "pending sequence references only retained requests")
    moved.pendingIndex = index
  end
  if worker.pendingRequestCursor > #pendingIds then
    worker.pendingRequestCursor = 1
  end
end

-- Re-observe still-pending application-originated requests after session
-- progress and emit exactly one terminal event per settled request. Each
-- flush visits at most REQUEST_OBSERVATIONS_PER_STEP pending records in
-- round-robin order from the retained cursor, so controller work stays
-- bounded while every survivor is eventually revisited. A terminal
-- removal keeps the cursor on its slot so the swapped replacement is
-- examined next; a per-flush observed set skips a replacement that was
-- already observed earlier in the same flush after a wrap, so no record
-- is re-observed twice in one flush. Emitted records leave both the map
-- and the sequence, so a terminal fact can never be pushed twice and
-- memory stays bounded by the selection lifecycle.
function Worker:_flushTerminalRequests()
  if self.session == nil or self.liveEpoch == nil then
    return
  end
  local pendingIds = self.pendingRequestIds
  local startCount = #pendingIds
  if startCount == 0 then
    return
  end
  local epoch = self.liveEpoch
  local budget = startCount
  if budget > REQUEST_OBSERVATIONS_PER_STEP then
    budget = REQUEST_OBSERVATIONS_PER_STEP
  end
  local cursor = self.pendingRequestCursor
  if type(cursor) ~= "number" or cursor < 1 or cursor > #pendingIds then
    cursor = 1
  end
  local visited = 0
  ---@type table<integer, boolean> request identities already observed by this flush
  local observed = {}
  local skipped = 0
  while visited < budget and #pendingIds > 0 do
    if cursor > #pendingIds then
      cursor = 1
    end
    local requestId = pendingIds[cursor]
    if observed[requestId] then
      cursor = cursor + 1
      skipped = skipped + 1
      if skipped > #pendingIds then
        break
      end
    else
      observed[requestId] = true
      skipped = 0
      local record = self.requests[requestId]
      assert(record ~= nil, "pending sequence references only retained requests")
      assert(record.pendingIndex == cursor, "pending slot matches its record")
      local observation = self:_observe(record.params)
      visited = visited + 1
      if observation.state == "ready" or observation.state == "failed" then
        self.pendingRequestCursor = cursor
        dropPendingRequest(self, requestId)
        cursor = self.pendingRequestCursor
        self:_emitRequestResult(epoch, requestId, observation)
      else
        cursor = cursor + 1
        if cursor > #pendingIds then
          cursor = 1
        end
      end
    end
  end
  if #pendingIds == 0 then
    self.pendingRequestCursor = 1
  else
    self.pendingRequestCursor = cursor
  end
end

local function formatError(value)
  if type(value) == "string" then
    return value
  end
  return tostring(value)
end

---@param params table<string, unknown>
---@return string|nil selector error for an invalid current-epoch message
local function validateSelectors(params)
  local kind = params.requestKind
  if not VALID_KINDS[kind] then
    return "unknown cache request kind: " .. tostring(kind)
  end
  if not VALID_URGENCIES[params.urgency] then
    return "unknown cache urgency: " .. tostring(params.urgency)
  end
  if kind == "milestone" then
    if
      params.name ~= "bootstrap"
      and params.name ~= "new-game-intro"
      and params.name ~= "field-planning"
      and params.name ~= "field-runtime"
      and params.name ~= "startup-title"
      and params.name ~= "startup-audio"
    then
      return "unknown milestone: " .. tostring(params.name)
    end
  elseif kind == "field" or kind == "logical-field" then
    if type(params.mapId) ~= "number" or params.mapId % 1 ~= 0 or params.mapId < 0 then
      return kind .. " request needs a non-negative integer mapId"
    end
  elseif kind == "cell" then
    if type(params.matrixMemberId) ~= "number" or params.matrixMemberId % 1 ~= 0 or params.matrixMemberId < 0 then
      return "cell request needs a non-negative integer matrixMemberId"
    end
    if type(params.index) ~= "number" or params.index % 1 ~= 0 or params.index < 0 then
      return "cell request needs a non-negative integer index"
    end
  elseif kind == "portrait" then
    if type(params.pageId) ~= "number" or params.pageId % 1 ~= 0 or params.pageId < 0 then
      return "portrait request needs a non-negative integer pageId"
    end
  elseif kind == "icon-page" then
    if type(params.pageId) ~= "number" or params.pageId % 1 ~= 0 or params.pageId < 0 then
      return "icon request needs a non-negative integer pageId"
    end
  elseif kind == "audio-bank" then
    if type(params.bankId) ~= "number" or params.bankId % 1 ~= 0 or params.bankId < 0 then
      return "audio-bank request needs a non-negative integer bankId"
    end
  elseif kind == "battle-scene" then
    local Sources = require("romdump.src.config.BattlePresentationSources")
    if not Sources.validateSceneKey(params.sceneKey) then
      return "battle-scene request needs its background/terrain/time sceneKey"
    end
  elseif kind == "pokedex" then
    -- The selector-free pokedex demand carries no job, source, page, or
    -- map identity: urgency alone rides the registered global job.
    for _, field in ipairs({ "name", "mapId", "matrixMemberId", "index", "pageId", "sceneKey", "bankId" }) do
      if params[field] ~= nil then
        return "pokedex request carries no " .. field .. " selector"
      end
    end
  elseif kind == "battle-effect" then
    if type(params.effectKey) ~= "string" or params.effectKey == "" or params.effectKey:find("/", 1, true) ~= nil then
      return "battle-effect request needs its flat effectKey"
    end
  elseif kind == "battle-presentation" then
    -- The shared battle catalog is one global job: urgency alone rides it.
    for _, field in ipairs({ "name", "mapId", "matrixMemberId", "index", "pageId", "sceneKey", "bankId", "effectKey" }) do
      if params[field] ~= nil then
        return "battle-presentation request carries no " .. field .. " selector"
      end
    end
  elseif kind == "startup-walker" then
    if
      type(params.pairIndex) ~= "number"
      or params.pairIndex % 1 ~= 0
      or params.pairIndex < 1
      or params.pairIndex > 32
    then
      return "startup-walker request needs an integer pairIndex 1..32"
    end
    for _, field in ipairs({
      "name",
      "mapId",
      "matrixMemberId",
      "index",
      "pageId",
      "sceneKey",
      "bankId",
      "effectKey",
      "sceneNumber",
    }) do
      if params[field] ~= nil then
        return "startup-walker request carries no " .. field .. " selector"
      end
    end
  elseif kind == "opening-scene" then
    if
      type(params.sceneNumber) ~= "number"
      or params.sceneNumber % 1 ~= 0
      or params.sceneNumber < 1
      or params.sceneNumber > 5
    then
      return "opening-scene request needs an integer sceneNumber 1..5"
    end
    for _, field in ipairs({ "name", "mapId", "matrixMemberId", "index", "pageId", "sceneKey", "bankId", "pairIndex" }) do
      if params[field] ~= nil then
        return "opening-scene request carries no " .. field .. " selector"
      end
    end
  end
  return nil
end

---@param params table<string, unknown>
---@return boolean ready
---@return string? failure
function Worker:_invoke(params)
  local session = assert(self.session, "controller has no selected session")
  local kind, urgency = params.requestKind, params.urgency
  if kind == "milestone" then
    return session:requestMilestone(params.name, urgency)
  elseif kind == "field" then
    return session:requestField(params.mapId, urgency)
  elseif kind == "logical-field" then
    return session:requestLogicalField(params.mapId, urgency)
  elseif kind == "cell" then
    return session:requestCell({ matrixMemberId = params.matrixMemberId, index = params.index }, urgency)
  elseif kind == "portrait" then
    return session:requestMonPortraitPage(params.pageId, urgency)
  elseif kind == "audio-bank" then
    return session:requestJob("audio-bank", tostring(params.bankId), urgency)
  elseif kind == "icon-page" then
    return session:requestIconPage(params.pageId, urgency)
  elseif kind == "pokedex" then
    return session:requestJob("pokedex", "global", urgency)
  elseif kind == "battle-scene" then
    return session:requestJob("battle-scene", params.sceneKey, urgency)
  elseif kind == "battle-effect" then
    return session:requestJob("battle-effect", params.effectKey, urgency)
  elseif kind == "battle-presentation" then
    return session:requestJob("battle-presentation", "global", urgency)
  elseif kind == "startup-walker" then
    return session:requestStartupWalker(params.pairIndex, urgency)
  elseif kind == "opening-scene" then
    return session:requestOpeningScene(params.sceneNumber, urgency)
  end
  error("unknown cache request kind: " .. tostring(kind), 0)
end

---@param params table<string, unknown>
---@return table<string, unknown> observation with terminal state/errorCode/errorMessage only
function Worker:_observe(params)
  -- Terminal observation only: request packets carry state and failure
  -- facts, never progress counts, so readiness answers decide alone.
  -- Progress stays on the session milestoneStatus boundary for its own
  -- consumers; this observation performs no progress query.
  local observation = { state = "pending", errorCode = "", errorMessage = "" }
  if self.session == nil then
    observation.state = "failed"
    observation.errorCode = "no-selection"
    observation.errorMessage = "controller has no selected session"
    return observation
  end
  local ok, ready, failure = pcall(function()
    return self:_invoke(params)
  end)
  if not ok then
    observation.state = "failed"
    observation.errorCode = "request"
    observation.errorMessage = formatError(ready)
    return observation
  end
  if failure ~= nil then
    observation.state = "failed"
    observation.errorCode = "cache"
    observation.errorMessage = formatError(failure)
    return observation
  end
  if ready then
    observation.state = "ready"
  end
  return observation
end

---@param versionId string
---@param development boolean
---@param repositoryRoot string?
---@return string|nil producerId
---@return string|nil failure
function Worker:_producerId(versionId, development, repositoryRoot)
  if not development then
    local counter = DerivedCacheVersions[versionId]
    if type(counter) ~= "number" or counter % 1 ~= 0 or counter < 1 then
      return nil, "release counter must be a positive integer for version: " .. tostring(versionId)
    end
    return "r" .. tostring(counter), nil
  end
  if type(repositoryRoot) ~= "string" or repositoryRoot == "" then
    return nil, "development selection requires its repository root"
  end
  if self.frozenProducerRoot == repositoryRoot and self.frozenProducerId ~= nil then
    return self.frozenProducerId, nil
  end
  local ok, backend = pcall(ProducerFingerprint.checkoutBackend, repositoryRoot)
  if not ok then
    return nil, "development producer backend is unavailable: " .. formatError(backend)
  end
  local digestOk, producerId = pcall(ProducerFingerprint.compute, backend)
  if not digestOk then
    return nil, "development producer digest failed: " .. formatError(producerId)
  end
  self.frozenProducerRoot = repositoryRoot
  self.frozenProducerId = producerId
  return producerId, nil
end

---@param command table<string, unknown>
function Worker:_answerSelect(command)
  self.reply:push({
    op = "select-result",
    epoch = command.epoch,
    ok = command.ok == true,
    generationId = command.generationId or "",
    lifecycle = self.lifecycle,
    errorMessage = command.errorMessage or "",
  })
end

---@param command table<string, unknown>
function Worker:_applySelect(command)
  local epoch = command.epoch
  local versionId = command.versionId
  if type(versionId) ~= "string" or versionId == "" then
    self:_fail("controller select requires a version")
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller select requires a version" })
    return
  end
  local infoOk, info = pcall(GameVersion.info, versionId)
  if not infoOk or type(info) ~= "table" or type(info.sha1) ~= "string" then
    self:_fail("unsupported version: " .. tostring(versionId))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "unsupported version: " .. tostring(versionId) })
    return
  end
  local development = command.development == true
  local repositoryRoot = command.repositoryRoot
  local producerId, producerError = self:_producerId(versionId, development, repositoryRoot)
  if producerId == nil then
    assert(type(producerError) == "string", "controller producer identity failed without a cause")
    self:_fail(producerError)
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = producerError })
    return
  end
  local identityOk, identity = pcall(DerivedCacheState.currentForSelection, {
    versionId = versionId,
    romSha1 = info.sha1,
    producerId = producerId,
    developmentRepositoryRoot = development and repositoryRoot or nil,
  })
  if not identityOk then
    self:_fail("controller selection identity failed: " .. formatError(identity))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller selection identity failed" })
    return
  end
  local poolOk, poolError = pcall(function()
    return self:_ensurePool(development and repositoryRoot or nil)
  end)
  if not poolOk then
    self:_fail("controller compiler pool is unavailable: " .. formatError(poolError))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller compiler pool is unavailable" })
    return
  end
  local selectOk, selectError = pcall(function()
    self:_replaceSession(identity, epoch)
  end)
  if not selectOk then
    self:_fail("controller generation selection failed: " .. formatError(selectError))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller generation selection failed" })
    return
  end
  self.selectedVersionId = versionId
  self.selectedRomSha1 = info.sha1
  self.selectedIdentity = identity
  self.offerError = nil
  self.attestedFor = nil
  self.attestationNote = nil
  self.liveEpoch = epoch
  self.lastRetiredEpoch = nil
  self.lifecycle = "active"
  self.requests = {}
  self.pendingRequestIds = {}
  self.pendingRequestCursor = 1
  self:_answerSelect({ epoch = epoch, ok = true, generationId = identity.generationId })
end

---@param repositoryRoot string?
---@return table<string, unknown> process compiler pool for the controller
function Worker:_ensurePool(repositoryRoot)
  if self.pool ~= nil and self.poolRoot == (repositoryRoot or false) then
    return self.pool
  end
  if self.pool ~= nil then
    pcall(function()
      self.pool:shutdown()
    end)
    self.pool = nil
  end
  local pool = CompilerPool.new({ mode = "interactive", developmentRepositoryRoot = repositoryRoot })
  self.pool = pool
  self.poolRoot = repositoryRoot or false
  return pool
end

---@param identity table<string, unknown>
---@param epoch integer
function Worker:_replaceSession(identity, epoch)
  if self.session ~= nil then
    pcall(function()
      self.session:retire()
    end)
    self.session = nil
  end
  if self.pool ~= nil and self.liveEpoch ~= nil then
    pcall(function()
      self.pool:retireSelection(self.liveEpoch)
    end)
  end
  local pool = assert(self.pool, "controller has no compiler pool")
  pool:selectGeneration(identity, epoch)
  self.session = InteractiveCacheBuild.new({ identity = identity, epoch = epoch, pool = pool })
end

---@param command table<string, unknown>
function Worker:_applyRequest(command)
  if command.epoch ~= self.liveEpoch or self.session == nil then
    return
  end
  local params = {
    requestKind = command.requestKind,
    urgency = command.urgency,
    name = command.name,
    mapId = command.mapId,
    matrixMemberId = command.matrixMemberId,
    index = command.index,
    pageId = command.pageId,
    sceneKey = command.sceneKey,
    bankId = command.bankId,
    effectKey = command.effectKey,
    pairIndex = command.pairIndex,
    sceneNumber = command.sceneNumber,
  }
  local selectorError = validateSelectors(params)
  if selectorError ~= nil then
    self.reply:push({
      op = "request-result",
      epoch = command.epoch,
      requestId = command.requestId,
      state = "failed",
      errorMessage = selectorError,
      errorCode = "protocol",
    })
    return
  end
  if self.requests[command.requestId] ~= nil then
    dropPendingRequest(self, command.requestId)
  end
  self.requests[command.requestId] = { params = params }
  local observation = self:_observe(params)
  if observation.state == "ready" or observation.state == "failed" then
    self.requests[command.requestId] = nil
    self:_emitRequestResult(command.epoch, command.requestId, observation)
  else
    trackPendingRequest(self, command.requestId)
  end
end

---@param command table<string, unknown>
function Worker:_applyPromote(command)
  if command.epoch ~= self.liveEpoch or self.session == nil then
    return
  end
  local record = self.requests[command.requestId]
  if record == nil then
    return
  end
  record.params.urgency = "required"
  local observation = self:_observe(record.params)
  if observation.state == "ready" or observation.state == "failed" then
    dropPendingRequest(self, command.requestId)
    self:_emitRequestResult(command.epoch, command.requestId, observation)
  end
end

---@param command table<string, unknown>
function Worker:_applyEnableSweep(command)
  if command.epoch ~= self.liveEpoch or self.session == nil then
    return
  end
  local ok, failure = pcall(function()
    self.session:enableSweep()
  end)
  if not ok then
    self:_fail("controller background authorization failed: " .. formatError(failure))
  end
end

---@param command table<string, unknown>
function Worker:_applyOfferSource(command)
  -- A validated import hands its one immutable buffer to the pool exactly
  -- once for the live epoch. The epoch must be live; version identity is
  -- enforced when the selection recorded it. Acceptance is acknowledged,
  -- never silent: the exact acknowledgement shape stays ours, and a stale
  -- or foreign offer is refused visibly without touching the pool.
  local epoch = command.epoch
  local function reject(cause)
    -- A live-epoch refusal is retained as the epoch's boot error: the
    -- gate below replays it instead of admitting gameplay on other
    -- grounds. Foreign-epoch refusals stay visible but touch no live state.
    if epoch == self.liveEpoch then
      self.offerError = cause
    end
    self.reply:push({ op = "offer-source-result", epoch = epoch, ok = false, errorMessage = cause })
  end
  if type(epoch) ~= "number" or epoch ~= self.liveEpoch or self.lifecycle == "failed" then
    reject("source offer does not match the live epoch")
    return
  end
  if type(command.byteData) ~= "userdata" then
    reject("source offer carries no shared buffer")
    return
  end
  if self.selectedVersionId ~= nil and command.versionId ~= self.selectedVersionId then
    reject("source offer names another version")
    return
  end
  if self.selectedRomSha1 ~= nil and command.romSha1 ~= self.selectedRomSha1 then
    reject("source offer identity does not match the selection")
    return
  end
  local pool = self.pool
  if pool == nil then
    reject("the controller has no compiler pool")
    return
  end
  local ok, accepted = pcall(function()
    return pool:offerSource(epoch, command.byteData, {
      versionId = command.versionId,
      romSha1 = command.romSha1,
    })
  end)
  if not ok then
    reject("the compiler pool refused the source offer")
    return
  end
  self.reply:push({ op = "offer-source-result", epoch = epoch, ok = accepted ~= false })
end

-- Typed source failures carry their ROM cause; every other failure is
-- controller, storage, or host infrastructure. Classification reads only
-- the stable error code, never message text.
---@param failure unknown plain typed error or message
---@return boolean sourceRequired
local function isSourceFailure(failure)
  if type(failure) ~= "table" or type(failure.code) ~= "string" then
    return false
  end
  local code = failure.code
  return code == "ROM_SOURCE_REQUIRED"
    or code == "ROM_OPEN_FAILED"
    or code == "ROM_READ_FAILED"
    or code == "ROM_SOURCE_MISMATCH"
    or code:sub(1, 4) == "ROM_"
    or code:sub(1, 4) == "ZIP_"
    or code:sub(1, 4) == "NDS_"
end

---@param detail unknown
---@return table<string, unknown> plain channel-safe typed detail
local function bootDetail(detail)
  if type(detail) == "table" and type(detail.code) == "string" then
    return {
      code = detail.code,
      message = type(detail.message) == "string" and detail.message or tostring(detail.message),
      context = type(detail.context) == "table" and detail.context or {},
    }
  end
  return { code = "SOURCE_UNAVAILABLE", message = tostring(detail) }
end

-- Boot-source gate for the live epoch: a strictly matching full-generation
-- attestation answers ready with zero ROM IO (dropping any unused offer),
-- otherwise the pool verifies and pins the one shared buffer before
-- gameplay is admitted. A refused offer fails the gate outright; missing,
-- unreadable, or mismatched sources report source-required while
-- infrastructure failures report failed. Exactly one reply per live check;
-- foreign epochs earn no reply and affect no state.
---@param command table<string, unknown>
function Worker:_applyCheckBootSource(command)
  local epoch = command.epoch
  if type(epoch) ~= "number" or epoch ~= self.liveEpoch or self.lifecycle == "failed" then
    return
  end
  local session = self.session
  local pool = self.pool
  local identity = self.selectedIdentity
  local function answer(state, detail)
    local packet = { op = "boot-source-result", epoch = epoch, state = state }
    if state ~= "ready" then
      packet.detail = bootDetail(detail)
    end
    self.reply:push(packet)
  end
  if session == nil or pool == nil or identity == nil then
    answer("failed", { code = "NO_SELECTION", message = "the controller has no live selection" })
    return
  end
  if self.offerError ~= nil then
    answer("failed", { code = "SOURCE_OFFER_REJECTED", message = self.offerError })
    return
  end
  local loadOk, stored = pcall(function()
    return session.cacheFs:loadLua(DerivedCacheState.path)
  end)
  if not loadOk then
    answer("failed", { code = "CACHE_BACKEND_FAILED", message = tostring(stored) })
    return
  end
  local current = DerivedCacheState.matches(stored, identity)
  if current then
    pcall(function()
      pool:prepareBootSource(epoch, false)
    end)
    answer("ready")
    return
  end
  local callOk, held, failure = pcall(function()
    return pool:prepareBootSource(epoch, true)
  end)
  if not callOk then
    answer("failed", { code = "POOL_PREFLIGHT_FAILED", message = tostring(held) })
    return
  end
  if held ~= true then
    if isSourceFailure(failure) then
      answer("source-required", failure)
    else
      answer("failed", failure)
    end
    return
  end
  answer("ready")
end

-- Durable full-generation attestation after a genuinely exhaustive
-- successful sweep or an explicitly requested complete build: every
-- selected entry terminal, no failure, nothing queued or running, and the
-- opening closure ready. Failed, partial, or merely first-play-complete
-- states publish nothing. Publication is atomic and once per generation;
-- the boot hold releases once terminal work no longer needs it. A failed
-- write is non-destructive: no marker, assets untouched, the boot hold
-- still releases, retried on a later pump.
function Worker:_maybeAttestCompletedGeneration()
  local epoch = self.liveEpoch
  local session = self.session
  local pool = self.pool
  local identity = self.selectedIdentity
  if epoch == nil or session == nil or pool == nil or identity == nil then
    return
  end
  if type(session.status) ~= "function" or type(session.cacheFs) ~= "table" then
    return
  end
  local statusOk, status = pcall(function()
    return session:status()
  end)
  if not statusOk or type(status) ~= "table" then
    return
  end
  local exhausted = status.sweepState == "exhausted" and status.sweepFailure == nil
  local settled = (status.failed or 0) == 0 and (status.queued or 0) == 0 and (status.running or 0) == 0
  local opened = status.bootstrap == "ready"
  local success = status.complete == true or (exhausted and settled and opened)
  if not success then
    return
  end
  local generationId = session.generationId
  if type(generationId) ~= "string" or generationId ~= identity.generationId then
    return
  end
  if self.attestedFor == generationId then
    return
  end
  local storedOk, stored = pcall(function()
    return session.cacheFs:loadLua(DerivedCacheState.path)
  end)
  if storedOk and DerivedCacheState.matches(stored, identity) then
    self.attestedFor = generationId
    if type(pool.releaseBootSourceHold) == "function" then
      pcall(function()
        pool:releaseBootSourceHold(epoch)
      end)
    end
    return
  end
  local publishOk, publishErr = pcall(function()
    DerivedCacheState.publish(session.cacheFs, identity)
  end)
  if not publishOk then
    self.attestationNote = { generationId = generationId, error = tostring(publishErr) }
    if type(pool.releaseBootSourceHold) == "function" then
      pcall(function()
        pool:releaseBootSourceHold(epoch)
      end)
    end
    return
  end
  self.attestedFor = generationId
  self.attestationNote = nil
  if type(pool.releaseBootSourceHold) == "function" then
    pcall(function()
      pool:releaseBootSourceHold(epoch)
    end)
  end
end

---@param command table<string, unknown>
function Worker:_applyRetire(command)
  if command.epoch ~= self.liveEpoch then
    return
  end
  local pool = self.pool
  if pool ~= nil then
    local ok, failure = pcall(function()
      pool:retireSelection(command.epoch)
    end)
    if not ok then
      self:_fail("controller retirement failed: " .. formatError(failure))
      return
    end
  end
  if self.session ~= nil then
    pcall(function()
      self.session:retire()
    end)
    self.session = nil
  end
  if pool ~= nil then
    pcall(function()
      pool:update()
    end)
  end
  self.lastRetiredEpoch = command.epoch
  self.liveEpoch = nil
  self.selectedIdentity = nil
  self.offerError = nil
  self.requests = {}
  self.pendingRequestIds = {}
  self.pendingRequestCursor = 1
  self.lifecycle = "retiring"
  self:_emitBarrierResult(command.epoch, command.barrierId, "retire")
end

---@return boolean
function Worker:_pumpQuiesce()
  local pending = self.pendingQuiesce
  if pending == nil then
    return false
  end
  local pool = self.pool
  if pool == nil then
    self:_emitBarrierResult(pending.epoch, pending.barrierId, "quiesce")
    self.lifecycle = "quiescent"
    self.pendingQuiesce = nil
    return true
  end
  local ok, failure = pcall(function()
    pool:update()
  end)
  if not ok then
    self:_fail("controller quiescence drain failed: " .. formatError(failure))
    return false
  end
  local quietOk, quiet = pcall(function()
    return pool:isQuiescent()
  end)
  if not quietOk then
    self:_fail("controller quiescence observation failed: " .. formatError(quiet))
    return false
  end
  if quiet then
    self:_emitBarrierResult(pending.epoch, pending.barrierId, "quiesce")
    self.lifecycle = "quiescent"
    self.pendingQuiesce = nil
    local deferred = self.deferredSelect
    self.deferredSelect = nil
    if deferred ~= nil then
      self:_applySelect(deferred)
    end
    return true
  end
  return false
end

---@param command table<string, unknown>
function Worker:_applyQuiesce(command)
  if command.epoch ~= self.liveEpoch and command.epoch ~= self.lastRetiredEpoch then
    return
  end
  if self.pendingQuiesce ~= nil then
    return
  end
  local pool = self.pool
  if pool ~= nil then
    local ok, failure = pcall(function()
      pool:quiesce()
    end)
    if not ok then
      self:_fail("controller quiescence failed: " .. formatError(failure))
      return
    end
  end
  self.lifecycle = "quiescing"
  self.pendingQuiesce = { epoch = command.epoch, barrierId = command.barrierId }
  self:_pumpQuiesce()
end

---@param command unknown
function Worker:_handle(command)
  if type(command) ~= "table" then
    return
  end
  if self.exiting then
    return
  end
  local op = command.op
  if op == "shutdown" then
    self:_shutdown()
    return
  end
  if self.lifecycle == "failed" then
    return
  end
  if op == "select" then
    if self.pendingQuiesce ~= nil then
      self.deferredSelect = command
      return
    end
    local ok, failure = pcall(function()
      self:_applySelect(command)
    end)
    if not ok then
      self:_fail("controller select failed: " .. formatError(failure))
      self:_answerSelect({ epoch = command.epoch, ok = false, errorMessage = "controller select failed" })
    end
  elseif op == "request" then
    local ok, failure = pcall(function()
      self:_applyRequest(command)
    end)
    if not ok then
      self:_fail("controller request failed: " .. formatError(failure))
    end
  elseif op == "promote" then
    local ok, failure = pcall(function()
      self:_applyPromote(command)
    end)
    if not ok then
      self:_fail("controller promotion failed: " .. formatError(failure))
    end
  elseif op == "enableSweep" then
    self:_applyEnableSweep(command)
  elseif op == "offer-source" then
    local ok, failure = pcall(function()
      self:_applyOfferSource(command)
    end)
    if not ok then
      self.reply:push({
        op = "offer-source-result",
        epoch = type(command) == "table" and command.epoch or nil,
        ok = false,
        errorMessage = formatError(failure),
      })
    end
  elseif op == "check-boot-source" then
    local ok, failure = pcall(function()
      self:_applyCheckBootSource(command)
    end)
    if not ok then
      self.reply:push({
        op = "boot-source-result",
        epoch = type(command) == "table" and command.epoch or nil,
        state = "failed",
        detail = bootDetail({ code = "BOOT_GATE_FAILED", message = formatError(failure) }),
      })
    end
  elseif op == "retire" then
    local ok, failure = pcall(function()
      self:_applyRetire(command)
    end)
    if not ok then
      self:_fail("controller retirement failed: " .. formatError(failure))
    end
  elseif op == "quiesce" then
    local ok, failure = pcall(function()
      self:_applyQuiesce(command)
    end)
    if not ok then
      self:_fail("controller quiescence failed: " .. formatError(failure))
    end
  end
end

-- Terminal shutdown owns the one interactive cleanup window: it snapshots
-- the active version cache and identity, joins every compiler worker, and
-- only after a positively proved join runs the single proof-gated sweep
-- as a best-effort diagnostic. A retired or failed selection, a version
-- mismatch, or an unproved join skips deletion; no reply is emitted.
function Worker:_shutdown()
  local session = self.session
  local identity = self.selectedIdentity
  local cacheFs = type(session) == "table" and session.cacheFs or nil
  local candidate = type(cacheFs) == "table"
    and type(identity) == "table"
    and self.lifecycle ~= "failed"
    and type(identity.versionId) == "string"
    and type(identity.generationId) == "string"
    and identity.generationId ~= ""
    and cacheFs.versionId == identity.versionId
    and (self.selectedVersionId == nil or self.selectedVersionId == identity.versionId)
    and (type(session.generationId) ~= "string" or session.generationId == identity.generationId)
  local pool = self.pool
  self.exiting = true
  local joinOk, joinResult = true, true
  if pool ~= nil then
    joinOk, joinResult = pcall(pool.shutdown, pool)
  end
  self.session = nil
  self.pool = nil
  local proved = pool ~= nil and joinOk and joinResult == true
  if not candidate or not proved then
    return
  end
  assert(type(cacheFs) == "table", "terminal cleanup keeps its snapshotted version cache")
  assert(type(identity) == "table", "terminal cleanup keeps its snapshotted identity")
  local collected, outcome = pcall(function()
    local CacheMaintenance = require("romdump.src.build.CacheMaintenance")
    return CacheMaintenance.collectCurrentGeneration(cacheFs, identity, true)
  end)
  if collected then
    self.maintenanceNote = { result = outcome }
  else
    self.maintenanceNote = { fault = tostring(outcome) }
  end
end

-- Drain available commands (bounded), advance quiescence, then pump the
-- session or settle pool work. Test-driving calls step directly with fake
-- channels; the thread entry below adds blocking waits around it.
function Worker:step()
  local drained = 0
  while drained < 16 do
    local command = self.control:pop()
    if command == nil then
      break
    end
    drained = drained + 1
    self:_handle(command)
    if self.exiting then
      return
    end
  end
  if self.pendingQuiesce ~= nil then
    self:_pumpQuiesce()
    return
  end
  if self.session ~= nil then
    local ok, failure = pcall(function()
      self.session:update()
    end)
    if not ok then
      self:_fail("controller session pump failed: " .. formatError(failure))
    else
      self:_flushTerminalRequests()
      -- Sweep attestation never fails the controller: a backend fault
      -- only records its diagnostic and retries on a later pump.
      pcall(function()
        self:_maybeAttestCompletedGeneration()
      end)
    end
    return
  end
  if self.pool ~= nil then
    pcall(function()
      self.pool:update()
    end)
  end
end

-- One wait/drive decision: an already-queued command outranks every wait
-- choice, immediately runnable local work pumps with no sleep, an
-- external compiler or close wait keeps one bounded sleep before polling,
-- a session clock wait sleeps at most one live cadence before repumping,
-- and only a fully idle controller blocks on its control channel. A
-- quiescence barrier that can settle now pumps at once; one still waiting
-- on worker or close results keeps polling instead of blocking, since
-- those results arrive on pool-private channels. The injected timer
-- exists only for deterministic tests; production passes love.timer.
---@param timer table<string, function> provides sleep(seconds)
function Worker:driveOnce(timer)
  assert(type(timer) == "table" and type(timer.sleep) == "function", "controller drive needs its sleep timer")
  local command = self.control:pop()
  if command ~= nil then
    self:_handle(command)
    if not self.exiting then
      self:step()
    end
    return
  end
  local activity = "idle"
  if self.pool ~= nil then
    activity = self.pool:activityState()
  end
  local quiesceSettleable = self.pendingQuiesce ~= nil and (self.pool == nil or activity == "idle")
  local sessionRunnable = self.session ~= nil and self.session:hasRunnablePlanning()
  if quiesceSettleable or sessionRunnable or activity == "runnable" then
    self:step()
    return
  end
  if activity == "waiting" then
    timer.sleep(LIVE_TICK_SECONDS)
    self:step()
    return
  end
  if self.session ~= nil and self.session.nextPlanningWakeDelay ~= nil then
    local wakeDelay = self.session:nextPlanningWakeDelay()
    if wakeDelay ~= nil then
      assert(
        type(wakeDelay) == "number" and wakeDelay >= 0 and wakeDelay < math.huge,
        "session planning wake delay must be a finite non-negative number"
      )
      if wakeDelay <= 0 then
        self:step()
        return
      end
      timer.sleep(math.min(wakeDelay, LIVE_TICK_SECONDS))
      self:step()
      return
    end
  end
  local awakened = self.control:demand()
  self:_handle(awakened)
  if not self.exiting then
    self:step()
  end
end

-- Thread entry: every loop iteration is one drive decision above, so a
-- selected settled session blocks on its control channel instead of
-- polling on a fixed tick. Exits only on shutdown.
---@param control table<string, function>
---@param reply table<string, function>
function CacheControllerWorker.run(control, reply)
  local worker = Worker.new(control, reply)
  while not worker.exiting do
    local host = rawget(_G, "love")
    local timer = host and host.timer
    if type(timer) ~= "table" or type(timer.sleep) ~= "function" then
      timer = { sleep = idleSleep }
    end
    worker:driveOnce(timer)
  end
  worker:_shutdown()
end

CacheControllerWorker.Worker = Worker

return CacheControllerWorker
