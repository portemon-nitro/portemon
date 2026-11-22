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
local CacheArchive = require("romdump.src.build.CacheArchive")
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

-- One installation part carries at most this many committed references. Main
-- mirrors the bound; the controller never sends a part it would refuse.
local INSTALL_PART_ENTRIES = 128

-- Snapshot scheduling: a dirty generation waits out one short debounce before
-- its first capture so a burst of commits coalesces into one archive, a streak
-- that keeps growing is still attempted by its forced deadline, and a failed
-- attempt is not retried busily. Foreground readiness never consults any of
-- these numbers.
local SNAPSHOT_DEBOUNCE_SECONDS = 5
local SNAPSHOT_FORCE_SECONDS = 30
local SNAPSHOT_RETRY_SECONDS = 30

-- The bounded first-play closure: the four global scopes the app observes
-- together before it records first play. The controller proves them from
-- captured milestone facts rather than trusting the caller.
local FIRST_PLAY_MILESTONES = { "bootstrap", "new-game-intro", "field-planning", "field-runtime" }

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
pcall(require, "love.filesystem")
pcall(require, "love.data")
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
  ["easy-chat"] = true,
  ["battle-effect"] = true,
  ["battle-presentation"] = true,
  ["battle-trainer-picture"] = true,
  ["battle-ball"] = true,
  ["battle-evolution"] = true,
  ["startup-walker"] = true,
  ["opening-scene"] = true,
}
local VALID_URGENCIES = { required = true, near = true, sweep = true }

---@class CacheControllerSelection
---@field epoch integer
---@field versionId string
---@field development boolean
---@field repositoryRoot string?

-- One captured snapshot in flight and the latest pending dirty indication.
-- The writer's identity-qualified acknowledgement is what advances
-- persistedSequence; a failure only records a retry deadline.
---@class CacheControllerSnapshot
---@field thread table<string, function>|nil
---@field control table<string, function>|nil
---@field reply table<string, function>|nil
---@field active { versionId: string, generationId: string, epoch: integer, sequence: integer }|nil
---@field dirty boolean
---@field dirtySince number|nil
---@field firstDirtyAt number|nil
---@field retryAt number|nil
---@field persistedSequence integer
---@field lastError table<string, unknown>|nil

---@return CacheControllerSnapshot
local function newSnapshotState()
  return {
    thread = nil,
    control = nil,
    reply = nil,
    active = nil,
    dirty = false,
    dirtySince = nil,
    firstDirtyAt = nil,
    retryAt = nil,
    persistedSequence = 0,
    lastError = nil,
  }
end

-- Monotonic seconds for the snapshot deadlines. The injected timer only
-- sleeps; this clock is a separate read so tests can settle deadlines without
-- waiting on the host.
---@return number
local function hostClock()
  local host = rawget(_G, "love")
  if host ~= nil and type(host.timer) == "table" and type(host.timer.getTime) == "function" then
    return host.timer.getTime()
  end
  return os.clock()
end

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
    selectedIdentity = nil,
    offerError = nil,
    milestones = {},
    firstPlay = false,
    complete = false,
    sequence = 0,
    installedEpoch = nil,
    installedFacts = {},
    syncedPublication = 0,
    snapshot = newSnapshotState(),
    clock = hostClock,
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
  -- Main may not expose this fact before the bytes and facts it vouches for
  -- install, so every terminal fact names the sequence that carries them.
  local requiredSequence = self.sequence
  if self.installedEpoch ~= epoch then
    -- Nothing of this epoch has streamed yet: its bytes and facts install
    -- with the next sequence.
    requiredSequence = self.sequence + 1
  end
  local packet = {
    op = "request-result",
    epoch = epoch,
    requestId = requestId,
    state = observation.state,
    requiredSequence = requiredSequence,
  }
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

local VALID_MILESTONES = {
  bootstrap = true,
  ["new-game-intro"] = true,
  ["field-planning"] = true,
  ["field-runtime"] = true,
  ["startup-title"] = true,
  ["startup-audio"] = true,
}

local function isNonNegativeInteger(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

---@param params table<string, unknown>
---@param kind string
---@param fields string[]
---@return string? selector error for the first unexpected field
local function rejectExtraSelectors(params, kind, fields)
  for _, field in ipairs(fields) do
    if params[field] ~= nil then
      return kind .. " request carries no " .. field .. " selector"
    end
  end
  return nil
end

local NO_SELECTORS_12 = {
  "name",
  "mapId",
  "matrixMemberId",
  "index",
  "pageId",
  "sceneKey",
  "bankId",
  "effectKey",
  "trainerSelector",
  "ballSelector",
  "sceneNumber",
  "pairIndex",
}

---@param params table<string, unknown>
---@return string? selector error
local function checkMilestone(params)
  if not VALID_MILESTONES[params.name] then
    return "unknown milestone: " .. tostring(params.name)
  end
  return nil
end

---@param params table<string, unknown>
---@param kind string
---@return string? selector error
local function checkField(params, kind)
  if not isNonNegativeInteger(params.mapId) then
    return kind .. " request needs a non-negative integer mapId"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkCell(params)
  if not isNonNegativeInteger(params.matrixMemberId) then
    return "cell request needs a non-negative integer matrixMemberId"
  end
  if not isNonNegativeInteger(params.index) then
    return "cell request needs a non-negative integer index"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkPortrait(params)
  if not isNonNegativeInteger(params.pageId) then
    return "portrait request needs a non-negative integer pageId"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkIconPage(params)
  if not isNonNegativeInteger(params.pageId) then
    return "icon request needs a non-negative integer pageId"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkAudioBank(params)
  if not isNonNegativeInteger(params.bankId) then
    return "audio-bank request needs a non-negative integer bankId"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkBattleScene(params)
  local Sources = require("romdump.src.config.BattlePresentationSources")
  if not Sources.validateSceneKey(params.sceneKey) then
    return "battle-scene request needs its background/terrain/time sceneKey"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkEasyChat(params)
  -- The selector-free easy chat demand carries no job, source, page, or
  -- map identity: urgency alone rides the registered global job.
  return rejectExtraSelectors(params, "easy-chat", {
    "name",
    "mapId",
    "matrixMemberId",
    "index",
    "pageId",
    "sceneKey",
    "bankId",
    "trainerSelector",
    "ballSelector",
  })
end

---@param params table<string, unknown>
---@return string? selector error
local function checkPokedex(params)
  -- The selector-free pokedex demand carries no job, source, page, or
  -- map identity: urgency alone rides the registered global job.
  return rejectExtraSelectors(params, "pokedex", {
    "name",
    "mapId",
    "matrixMemberId",
    "index",
    "pageId",
    "sceneKey",
    "bankId",
    "trainerSelector",
    "ballSelector",
  })
end

---@param params table<string, unknown>
---@return string? selector error
local function checkBattleEffect(params)
  if type(params.effectKey) ~= "string" or params.effectKey == "" or params.effectKey:find("/", 1, true) ~= nil then
    return "battle-effect request needs its flat effectKey"
  end
  return nil
end

---@param params table<string, unknown>
---@return string? selector error
local function checkBattlePresentation(params)
  -- The shared battle catalog is one global job: urgency alone rides it.
  return rejectExtraSelectors(params, "battle-presentation", {
    "name",
    "mapId",
    "matrixMemberId",
    "index",
    "pageId",
    "sceneKey",
    "bankId",
    "effectKey",
    "trainerSelector",
    "ballSelector",
  })
end

---@param params table<string, unknown>
---@return string? selector error
local function checkBattleTrainerPicture(params)
  -- Source-independent syntax only: the worker compiles the exact
  -- spelling and the producer proves catalog membership. The receipt
  -- key never carries the colon. Lua patterns have no alternation, so
  -- the role stem is captured and required explicitly.
  local trainerRole, trainerClass
  if type(params.trainerSelector) == "string" then
    trainerRole, trainerClass = params.trainerSelector:match("^([a-z]+):([A-Z][A-Z0-9_]*)$")
  end
  if (trainerRole ~= "front" and trainerRole ~= "back") or trainerClass == nil then
    return "battle-trainer-picture request needs its front:CLASS or back:CLASS trainerSelector"
  end
  return rejectExtraSelectors(params, "battle-trainer-picture", {
    "name",
    "mapId",
    "matrixMemberId",
    "index",
    "pageId",
    "sceneKey",
    "bankId",
    "effectKey",
    "ballSelector",
    "sceneNumber",
    "pairIndex",
  })
end

---@param params table<string, unknown>
---@return string? selector error
local function checkBattleBall(params)
  if type(params.ballSelector) ~= "string" or params.ballSelector:match("^ball:[A-Z][A-Z0-9_]*$") == nil then
    return "battle-ball request needs its ball:ITEM ballSelector"
  end
  return rejectExtraSelectors(params, "battle-ball", {
    "name",
    "mapId",
    "matrixMemberId",
    "index",
    "pageId",
    "sceneKey",
    "bankId",
    "effectKey",
    "trainerSelector",
    "sceneNumber",
    "pairIndex",
  })
end

---@param params table<string, unknown>
---@return string? selector error
local function checkBattleEvolution(params)
  -- One global-keyed evolution job: urgency alone rides it.
  return rejectExtraSelectors(params, "battle-evolution", NO_SELECTORS_12)
end

---@param params table<string, unknown>
---@return string? selector error
local function checkStartupWalker(params)
  return rejectExtraSelectors(params, "startup-walker", NO_SELECTORS_12)
end

---@param params table<string, unknown>
---@return string? selector error
local function checkOpeningScene(params)
  if
    type(params.sceneNumber) ~= "number"
    or params.sceneNumber % 1 ~= 0
    or params.sceneNumber < 1
    or params.sceneNumber > 5
  then
    return "opening-scene request needs an integer sceneNumber 1..5"
  end
  return rejectExtraSelectors(params, "opening-scene", {
    "name",
    "mapId",
    "matrixMemberId",
    "index",
    "pageId",
    "sceneKey",
    "bankId",
    "pairIndex",
    "trainerSelector",
    "ballSelector",
  })
end

---@type table<string, fun(params: table<string, unknown>, kind: string): string?>
local SELECTOR_CHECKS = {
  milestone = checkMilestone,
  field = checkField,
  ["logical-field"] = checkField,
  cell = checkCell,
  portrait = checkPortrait,
  ["icon-page"] = checkIconPage,
  ["audio-bank"] = checkAudioBank,
  ["battle-scene"] = checkBattleScene,
  pokedex = checkPokedex,
  ["easy-chat"] = checkEasyChat,
  ["battle-effect"] = checkBattleEffect,
  ["battle-presentation"] = checkBattlePresentation,
  ["battle-trainer-picture"] = checkBattleTrainerPicture,
  ["battle-ball"] = checkBattleBall,
  ["battle-evolution"] = checkBattleEvolution,
  ["startup-walker"] = checkStartupWalker,
  ["opening-scene"] = checkOpeningScene,
}

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
  assert(type(kind) == "string", "cache request kind is a known string")
  local check = SELECTOR_CHECKS[kind]
  assert(check ~= nil, "cache request kind has its selector check")
  return check(params, kind)
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
  elseif kind == "easy-chat" then
    return session:requestJob("easy-chat", "global", urgency)
  elseif kind == "battle-scene" then
    return session:requestJob("battle-scene", params.sceneKey, urgency)
  elseif kind == "battle-effect" then
    return session:requestJob("battle-effect", params.effectKey, urgency)
  elseif kind == "battle-presentation" then
    return session:requestJob("battle-presentation", "global", urgency)
  elseif kind == "battle-trainer-picture" then
    -- The validated semantic selector maps to the canonical safe receipt
    -- key: the colon never reaches the filesystem.
    local role, classKey = params.trainerSelector:match("^([a-z]+):([A-Z][A-Z0-9_]*)$")
    assert(
      (role == "front" or role == "back") and classKey ~= nil,
      "battle-trainer-picture request needs its safe class key"
    )
    return session:requestJob("battle-trainer-picture", role .. "-" .. classKey, urgency)
  elseif kind == "battle-ball" then
    local itemKey = params.ballSelector:match("^ball:([A-Z][A-Z0-9_]*)$")
    assert(itemKey ~= nil, "battle-ball request needs its safe item key")
    return session:requestJob("battle-ball", itemKey, urgency)
  elseif kind == "battle-evolution" then
    return session:requestJob("battle-evolution", "global", urgency)
  elseif kind == "startup-walker" then
    return session:requestStartupWalker(urgency)
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

-- Captured milestone facts, sorted for the manifest and the installation
-- packets that carry them.
---@return string[] sortedNames
function Worker:_milestoneFacts()
  local names = {}
  for name in pairs(self.milestones) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- The recoverable snapshot for the selected generation, if this boot may use
-- one: a surviving backup is restored first, then the candidate is hydrated in
-- full against the expected identity. A damaged or foreign candidate yields no
-- hydration at all, so the selection takes the ordinary rebuild/source route.
---@param identity table<string, unknown>
---@return CacheArchive.Hydration|nil
function Worker:_hydrateSnapshot(identity)
  local versionId = assert(identity.versionId, "a hydrated selection names its version")
  CacheArchive.restoreBackup(versionId)
  local fileName = CacheArchive.recoverableFileName(versionId)
  if fileName == nil then
    return nil
  end
  local hydration, failure = CacheArchive.open(versionId, identity, fileName)
  if hydration == nil then
    self.snapshot.lastError = type(failure) == "table" and failure
      or { code = "CACHE_ARCHIVE_UNREADABLE", message = tostring(failure) }
    return nil
  end
  return hydration
end

-- One installation stream for main: the whole cut in parts of at most
-- INSTALL_PART_ENTRIES references, then the completion facts of that same cut.
-- Main exposes nothing before the matching commit.
---@param epoch integer
---@param generationId string
---@param sequence integer
---@param initial boolean
---@param identity table<string, unknown>
---@param entries { path: string, size: integer, sourceId: string, contentId: string, data: love.Data }[] sorted by path
function Worker:_emitInstallStream(epoch, generationId, sequence, initial, identity, entries)
  self.reply:push({
    op = "cache-install-begin",
    epoch = epoch,
    generationId = generationId,
    sequence = sequence,
    initial = initial,
    identity = identity,
    entryCount = #entries,
  })
  local part = 0
  local index = 1
  while index <= #entries do
    local slice = {}
    local last = math.min(index + INSTALL_PART_ENTRIES - 1, #entries)
    for position = index, last do
      slice[#slice + 1] = entries[position]
    end
    part = part + 1
    self.reply:push({
      op = "cache-install-entries",
      epoch = epoch,
      generationId = generationId,
      sequence = sequence,
      part = part,
      entries = slice,
    })
    index = last + 1
  end
  self.reply:push({
    op = "cache-install-commit",
    epoch = epoch,
    generationId = generationId,
    sequence = sequence,
    milestones = self:_milestoneFacts(),
    firstPlay = self.firstPlay,
    complete = self.complete,
  })
  self.sequence = sequence
  self.installedEpoch = epoch
end

-- The initial installation of a selection: the hydrated cut resumes at the
-- sequence it persisted under, and a selection without a candidate starts an
-- empty store at sequence 1 so the stream exists before any terminal
-- observation.
---@param identity table<string, unknown>
---@param epoch integer
---@param hydration CacheArchive.Hydration|nil
function Worker:_emitInitialInstallation(identity, epoch, hydration)
  local generationId = assert(identity.generationId, "a selection names its generation")
  if hydration == nil then
    self:_emitInstallStream(epoch, generationId, 1, true, identity, {})
    return
  end
  local reader = assert(self.pool and self.pool:cacheFs(), "a hydrated selection needs its resident view")
  local entries = {}
  for _, entry in ipairs(hydration.entries) do
    entries[#entries + 1] =
      assert(reader:resolveAsset(entry.path), "a hydrated payload is missing from the committed store: " .. entry.path)
  end
  table.sort(entries, function(left, right)
    return left.path < right.path
  end)
  self:_emitInstallStream(epoch, generationId, hydration.sequence, true, identity, entries)
end

-- Reset this selection's completion facts: a hydrated cut arrives with the
-- milestones, first play, and completeness its own capture proved, and every
-- other selection starts with none of them.
---@param hydration CacheArchive.Hydration|nil
function Worker:_resetSelectionFacts(hydration)
  self.milestones = {}
  self.firstPlay = false
  self.complete = false
  self.installedFacts = {}
  self.sequence = 0
  self.installedEpoch = nil
  self.syncedPublication = self.pool ~= nil and self.pool:publicationSequence() or 0
  local facts = self.pool ~= nil and self.pool:artifactFacts() or nil
  if facts ~= nil then
    for jobKey in pairs(facts.records) do
      self.installedFacts[jobKey] = true
    end
  end
  if hydration ~= nil then
    for _, name in ipairs(hydration.milestones) do
      self.milestones[name] = true
    end
    self.firstPlay = hydration.firstPlay == true
    self.complete = hydration.complete == true
  end
  local snapshot = self.snapshot
  snapshot.persistedSequence = hydration ~= nil and hydration.sequence or 0
  snapshot.dirty = false
  snapshot.dirtySince = nil
  snapshot.firstDirtyAt = nil
  snapshot.retryAt = nil
end

-- Mark that the resident cut moved past what a snapshot captured. Later
-- commits only refresh this indication; the cut itself is taken once, when the
-- writer can accept it.
function Worker:_markSnapshotDirty()
  local snapshot = self.snapshot
  local now = self.clock()
  snapshot.dirty = true
  snapshot.dirtySince = now
  if snapshot.firstDirtyAt == nil then
    snapshot.firstDirtyAt = now
  end
end

-- Refresh the completion facts this selection can prove right now: the
-- milestone scopes the session has proven and the exhaustive corpus decision.
-- A proven generation releases its boot hold at once; persistence is a
-- separate observation and never appears here.
---@return boolean changed a completion fact became true during this refresh
function Worker:_refreshCompletionFacts()
  local session = self.session
  local pool = self.pool
  local identity = self.selectedIdentity
  local epoch = self.liveEpoch
  if session == nil or pool == nil or identity == nil or epoch == nil then
    return false
  end
  local changed = false
  if type(session.milestoneFacts) == "function" then
    local names = session:milestoneFacts()
    for _, name in ipairs(names) do
      if self.milestones[name] == nil then
        self.milestones[name] = true
        changed = true
      end
    end
  end
  if self.complete then
    return changed
  end
  if type(session.generationId) == "string" and session.generationId ~= identity.generationId then
    return changed
  end
  local statusOk, status = pcall(session.status, session)
  if not statusOk or type(status) ~= "table" then
    return changed
  end
  local exhausted = status.sweepState == "exhausted" and status.sweepFailure == nil
  local settled = (status.failed or 0) == 0 and (status.queued or 0) == 0 and (status.running or 0) == 0
  local opened = status.bootstrap == "ready"
  if status.complete == true or (exhausted and settled and opened) then
    self.complete = true
    changed = true
    if type(pool.releaseBootSourceHold) == "function" then
      pcall(function()
        pool:releaseBootSourceHold(epoch)
      end)
    end
  end
  return changed
end

-- Publish every newly committed artifact and every changed completion fact of
-- this selection as one installation sequence. Bytes precede the facts that
-- vouch for them, and the call is skipped entirely when nothing moved.
---@param force boolean? publish a completion fact this call just recorded
---@return boolean published
function Worker:_publishInstallation(force)
  local pool = self.pool
  local identity = self.selectedIdentity
  local epoch = self.liveEpoch
  if pool == nil or identity == nil or epoch == nil or self.session == nil then
    return false
  end
  local changedFacts = self:_refreshCompletionFacts()
  local facts = pool:artifactFacts()
  if facts == nil then
    return false
  end
  if pool:publicationSequence() == self.syncedPublication and not changedFacts and force ~= true then
    return false
  end
  local fresh = {}
  for jobKey, fact in pairs(facts.records) do
    if self.installedFacts[jobKey] == nil then
      fresh[#fresh + 1] = fact
    end
  end
  table.sort(fresh, function(left, right)
    return left.kind .. ":" .. left.key < right.kind .. ":" .. right.key
  end)
  local reader = assert(pool:cacheFs(), "a publication needs the committed resident view")
  local entries = {}
  local seen = {}
  for _, fact in ipairs(fresh) do
    for _, path in ipairs(fact.files) do
      if not seen[path] then
        seen[path] = true
        entries[#entries + 1] =
          assert(reader:resolveAsset(path), "committed artifact file is missing from the store: " .. path)
      end
    end
  end
  table.sort(entries, function(left, right)
    return left.path < right.path
  end)
  self:_emitInstallStream(epoch, identity.generationId, self.sequence + 1, false, identity, entries)
  for _, fact in ipairs(fresh) do
    self.installedFacts[fact.kind .. ":" .. fact.key] = true
  end
  self.syncedPublication = pool:publicationSequence()
  self:_markSnapshotDirty()
  return true
end

-- Start the one process-owned archive writer, on demand: a host without thread
-- support keeps play working and simply never persists.
---@return boolean available
function Worker:_ensureArchiveWriter()
  local snapshot = self.snapshot
  if snapshot.thread ~= nil then
    local thread = snapshot.thread
    if type(thread.isRunning) ~= "function" then
      return true
    end
    local ok, running = pcall(thread.isRunning, thread)
    if not ok or running then
      return true
    end
    self:_discardArchiveWriter()
  end
  if snapshot.unavailable ~= nil then
    return false
  end
  local host = rawget(_G, "love")
  local threadApi = type(host) == "table" and host.thread or nil
  if
    type(threadApi) ~= "table"
    or type(threadApi.newChannel) ~= "function"
    or type(threadApi.newThread) ~= "function"
  then
    snapshot.unavailable = "the snapshot writer requires love.thread"
    return false
  end
  local ok, control, reply, thread = pcall(function()
    local controlChannel = threadApi.newChannel()
    local replyChannel = threadApi.newChannel()
    local writerThread = threadApi.newThread(CacheArchive.bootstrap())
    writerThread:start(controlChannel, replyChannel, package.path)
    return controlChannel, replyChannel, writerThread
  end)
  if not ok or control == nil or reply == nil or thread == nil then
    snapshot.unavailable = "the snapshot writer could not be started: " .. formatError(control)
    return false
  end
  snapshot.control = control
  snapshot.reply = reply
  snapshot.thread = thread
  return true
end

-- A stopped writer cannot consume another command. Join it and detach both
-- channels so no late packet can settle a capture owned by its replacement.
function Worker:_discardArchiveWriter()
  local snapshot = self.snapshot
  local thread = snapshot.thread
  if thread ~= nil and type(thread.wait) == "function" then
    pcall(thread.wait, thread)
  end
  snapshot.thread = nil
  snapshot.control = nil
  snapshot.reply = nil
end

-- Capture the latest consistent cut for the writer: the committed bytes and
-- facts of the installed sequence plus this selection's completion facts. Only
-- when the writer can accept it, and at most one capture is ever in flight.
---@return boolean captured
function Worker:_captureSnapshot()
  local snapshot = self.snapshot
  local pool = self.pool
  local identity = self.selectedIdentity
  local epoch = self.liveEpoch
  if pool == nil or identity == nil or epoch == nil or self.session == nil or snapshot.active ~= nil then
    return false
  end
  if not self:_ensureArchiveWriter() then
    -- A host that cannot host the writer keeps playing and stops asking: the
    -- generated bytes stay resident-only for this process.
    snapshot.dirty = false
    snapshot.dirtySince = nil
    snapshot.firstDirtyAt = nil
    return false
  end
  local cut = pool:snapshotCut(identity, {
    sequence = self.sequence,
    milestones = self:_milestoneFacts(),
    firstPlay = self.firstPlay,
    complete = self.complete,
  })
  local pushed, pushError = pcall(function()
    local control = assert(snapshot.control, "the snapshot writer owns its control channel")
    control:push({
      op = "snapshot",
      versionId = cut.versionId,
      generationId = identity.generationId,
      epoch = epoch,
      identity = cut.identity,
      sequence = cut.sequence,
      entries = cut.entries,
      artifacts = cut.artifacts,
      milestones = cut.milestones,
      firstPlay = cut.firstPlay,
      complete = cut.complete,
    })
  end)
  if not pushed then
    snapshot.lastError = { code = "CACHE_ARCHIVE_WRITE_FAILED", message = formatError(pushError) }
    snapshot.retryAt = self.clock() + SNAPSHOT_RETRY_SECONDS
    return false
  end
  snapshot.active = {
    versionId = cut.versionId,
    generationId = identity.generationId,
    epoch = epoch,
    sequence = cut.sequence,
  }
  snapshot.dirty = false
  snapshot.dirtySince = nil
  snapshot.firstDirtyAt = nil
  return true
end

-- Settle one writer acknowledgement. Only the exact captured identity advances
-- persistedSequence; a failure only arms the retry deadline and reports once.
---@param packet table<string, unknown>
function Worker:_settleSnapshotReply(packet)
  local snapshot = self.snapshot
  local active = snapshot.active
  if active == nil then
    return
  end
  if
    packet.versionId ~= active.versionId
    or packet.generationId ~= active.generationId
    or packet.epoch ~= active.epoch
    or packet.sequence ~= active.sequence
  then
    return
  end
  snapshot.active = nil
  if packet.op == "snapshot-persisted" then
    snapshot.lastError = nil
    snapshot.retryAt = nil
    if active.sequence > snapshot.persistedSequence then
      snapshot.persistedSequence = active.sequence
    end
    if self.liveEpoch == active.epoch then
      self.reply:push({
        op = "cache-persistence-succeeded",
        versionId = active.versionId,
        generationId = active.generationId,
        epoch = active.epoch,
        sequence = active.sequence,
      })
    end
    return
  end
  local now = self.clock()
  snapshot.lastError = type(packet.error) == "table" and packet.error
    or { code = "CACHE_ARCHIVE_WRITE_FAILED", message = formatError(packet.error) }
  snapshot.retryAt = now + SNAPSHOT_RETRY_SECONDS
  -- The cut is still unpersisted, so it stays dirty; the retry deadline, not a
  -- busy loop, decides when the newest cut is tried again.
  if self.liveEpoch == active.epoch and self.session ~= nil then
    snapshot.dirty = true
    snapshot.dirtySince = now
    if snapshot.firstDirtyAt == nil then
      snapshot.firstDirtyAt = now
    end
  end
  if self.liveEpoch == active.epoch then
    self.reply:push({
      op = "cache-persistence-failed",
      versionId = active.versionId,
      generationId = active.generationId,
      epoch = active.epoch,
      sequence = active.sequence,
      error = snapshot.lastError,
    })
  end
end

-- Drain writer acknowledgements and start the next capture when the coalescing
-- debounce, the forced deadline, and the retry gate all allow it. Play never
-- waits here: a slow, failing, or absent writer only leaves the cut dirty.
function Worker:_pumpSnapshot()
  local snapshot = self.snapshot
  if snapshot.reply ~= nil then
    while true do
      local packet = snapshot.reply:pop()
      if type(packet) ~= "table" then
        break
      end
      self:_settleSnapshotReply(packet)
    end
  end
  -- A writer that stopped without answering settles its capture as a failure:
  -- the controller never waits on a channel nobody will push to.
  local thread = snapshot.thread
  if thread ~= nil and type(thread.isRunning) == "function" then
    local probeOk, running = pcall(thread.isRunning, thread)
    if probeOk and not running then
      if snapshot.active ~= nil then
        self:_settleSnapshotReply({
          op = "snapshot-failed",
          versionId = snapshot.active.versionId,
          generationId = snapshot.active.generationId,
          epoch = snapshot.active.epoch,
          sequence = snapshot.active.sequence,
          error = { code = "CACHE_ARCHIVE_WRITE_FAILED", message = "the snapshot writer stopped unexpectedly" },
        })
      end
      self:_discardArchiveWriter()
    end
  end
  if snapshot.active ~= nil or not snapshot.dirty then
    return
  end
  if self.session == nil or self.selectedIdentity == nil or self.pool == nil then
    return
  end
  local now = self.clock()
  if snapshot.retryAt ~= nil and now < snapshot.retryAt then
    return
  end
  local debounceDue = snapshot.dirtySince == nil or now - snapshot.dirtySince >= SNAPSHOT_DEBOUNCE_SECONDS
  local forceDue = snapshot.firstDirtyAt ~= nil and now - snapshot.firstDirtyAt >= SNAPSHOT_FORCE_SECONDS
  if not debounceDue and not forceDue then
    return
  end
  self:_captureSnapshot()
end

-- Retirement drops queued snapshot work and asks an active writer to stop
-- before promotion. The writer settles on its own; no gameplay path waits.
function Worker:_cancelSnapshot()
  local snapshot = self.snapshot
  snapshot.dirty = false
  snapshot.dirtySince = nil
  snapshot.firstDirtyAt = nil
  if snapshot.active ~= nil and snapshot.control ~= nil then
    pcall(function()
      local control = assert(snapshot.control, "the snapshot writer owns its control channel")
      control:push({ op = "cancel", sequence = snapshot.active.sequence })
    end)
  end
end

-- Terminal teardown joins the one archive writer. Nothing is deleted: a
-- pending snapshot is simply not taken.
function Worker:_closeArchiveWriter()
  local snapshot = self.snapshot
  local thread = snapshot.thread
  if thread == nil then
    return
  end
  if snapshot.control ~= nil then
    pcall(function()
      local control = assert(snapshot.control, "the snapshot writer owns its control channel")
      control:push({ op = "stop" })
    end)
  end
  pcall(thread.wait, thread)
  snapshot.thread = nil
  snapshot.control = nil
  snapshot.reply = nil
  snapshot.active = nil
end

-- Record first play for the live epoch: the fact exists only after the bounded
-- first-play closure is proven from captured milestone facts, and it reaches
-- main with its own installation sequence.
---@param command table<string, unknown>
function Worker:_applyRecordFirstPlay(command)
  if command.epoch ~= self.liveEpoch or self.session == nil or self.selectedIdentity == nil then
    return
  end
  if self.firstPlay then
    return
  end
  for _, name in ipairs(FIRST_PLAY_MILESTONES) do
    if self.milestones[name] == nil then
      return
    end
  end
  self.firstPlay = true
  self:_publishInstallation(true)
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
  local hydration = nil
  local selectOk, selectError = pcall(function()
    -- The candidate snapshot is hydrated before the session exists: its cut
    -- seeds the committed generation and its completion facts seed boot and
    -- first-play trust. A discarded candidate keeps its own diagnostic.
    self.snapshot.lastError = nil
    hydration = self:_hydrateSnapshot(identity)
    self:_replaceSession(identity, epoch, hydration)
    self.selectedIdentity = identity
    self.liveEpoch = epoch
    self:_resetSelectionFacts(hydration)
  end)
  if not selectOk then
    self:_fail("controller generation selection failed: " .. formatError(selectError))
    self:_answerSelect({ epoch = epoch, ok = false, errorMessage = "controller generation selection failed" })
    return
  end
  self.selectedVersionId = versionId
  self.selectedRomSha1 = info.sha1
  self.offerError = nil
  self.lastRetiredEpoch = nil
  self.lifecycle = "active"
  self.requests = {}
  self.pendingRequestIds = {}
  self.pendingRequestCursor = 1
  self:_answerSelect({ epoch = epoch, ok = true, generationId = identity.generationId })
  -- The initial installation follows the accepted selection: main owns the
  -- resident store before it observes any ready fact or constructs a
  -- consumer from the epoch's reader.
  local installOk, installError = pcall(function()
    self:_emitInitialInstallation(identity, epoch, hydration)
  end)
  if not installOk then
    self:_fail("controller generation installation failed: " .. formatError(installError))
  elseif hydration ~= nil then
    self.reply:push({
      op = "cache-persistence-succeeded",
      versionId = identity.versionId,
      generationId = identity.generationId,
      epoch = epoch,
      sequence = hydration.sequence,
    })
  end
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
---@param hydration CacheArchive.Hydration|nil
function Worker:_replaceSession(identity, epoch, hydration)
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
  if hydration ~= nil then
    pool:seedCommittedGeneration(hydration.entries, hydration.artifacts)
  end
  self.session = InteractiveCacheBuild.new({
    identity = identity,
    epoch = epoch,
    pool = pool,
    milestones = hydration ~= nil and hydration.milestones or nil,
  })
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
    trainerSelector = command.trainerSelector,
    ballSelector = command.ballSelector,
    pairIndex = command.pairIndex,
    sceneNumber = command.sceneNumber,
  }
  local selectorError = validateSelectors(params)
  if selectorError ~= nil then
    self:_emitRequestResult(command.epoch, command.requestId, {
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
  -- Completeness is a fact of the captured cut this selection hydrated or
  -- proved in this process, never a marker file beside the payloads.
  if self.complete then
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
  -- Retirement cancels queued snapshot work and asks an active writer to
  -- settle before any later same-version capture may start. The barrier does
  -- not wait for that writer; dirty progress may simply be dropped.
  self:_cancelSnapshot()
  self.lastRetiredEpoch = command.epoch
  self.liveEpoch = nil
  self.selectedIdentity = nil
  self.installedEpoch = nil
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
    self:_publishInstallation()
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
  elseif op == "record-first-play" then
    local ok, failure = pcall(function()
      self:_applyRecordFirstPlay(command)
    end)
    if not ok then
      self:_fail("controller first-play recording failed: " .. formatError(failure))
    end
  end
end

-- Terminal shutdown joins every compiler worker and drops the session and
-- pool. Superseded generated data is reclaimed only by an explicit cache
-- clear or whole-generation replacement, so shutdown deletes nothing; no
-- reply is emitted.
function Worker:_shutdown()
  local pool = self.pool
  self.exiting = true
  self:_cancelSnapshot()
  self:_closeArchiveWriter()
  if pool ~= nil then
    pcall(pool.shutdown, pool)
  end
  self.session = nil
  self.pool = nil
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
    self:_pumpSnapshot()
    return
  end
  if self.session ~= nil then
    -- Bytes and facts install first: a terminal observation emitted below
    -- names the sequence main must have before it may expose it.
    local ok, failure = pcall(function()
      self.session:update()
      self:_publishInstallation()
    end)
    if not ok then
      self:_fail("controller session pump failed: " .. formatError(failure))
    else
      self:_flushTerminalRequests()
    end
  elseif self.pool ~= nil then
    pcall(function()
      self.pool:update()
    end)
  end
  self:_pumpSnapshot()
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
  -- Persistence is a separate observation: a dirty cut or an outstanding
  -- writer acknowledgement keeps one bounded poll cadence, never a gameplay
  -- wait and never a busy loop.
  if self.snapshot.active ~= nil or self.snapshot.dirty then
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
