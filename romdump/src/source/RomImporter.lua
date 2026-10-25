-- First-run import orchestration and state machine. Two roles:
--
--   * RomImporter.isReady(versionId) -- the cheap source-binding readiness
--     contract the boot flow depends on. It never opens the ROM or reads
--     large resources: a strict persisted binding suffices, and the actual
--     source bytes are opened lazily on the first genuine cache miss.
--
--   * An interactive/headless importer driving validation inside a
--     coroutine: validate the ROM fully (NdsRom.open: size, SHA-1, header,
--     game code) BEFORE any cache mutation, then atomically record the
--     source binding, yielding periodically so the UI stays responsive.
--     Nothing is extracted: derived caches compile directly from the
--     user-owned ROM on demand. The validated bytes stay available exactly
--     once through takeVerifiedSource for the controller handoff; every
--     other terminal path releases the source and a single GC is run.
--
-- Progress is monotonic by construction (ordered phase fractions). All
-- love coupling is confined to the default `now` clock, the shared-buffer
-- conversion, and the lazy draw helper.

local GameVersion = require("romdump.src.source.GameVersion")
local CacheFs = require("libs.storage.src.CacheFs")
local RomBinding = require("romdump.src.source.RomBinding")
local RomSource = require("romdump.src.source.RomSource")
local NdsRom = require("romdump.src.source.NdsRom")
local Errors = require("libs.errors.src.Errors")

---@class RomImporter
---@field state string
---@field progress number?
---@field private _onComplete (fun(versionId: string, report: table<string, unknown>?): nil)?
---@field private _versions table<string, unknown>?
---@field private _cacheFactory (fun(versionId: string): table<string, unknown>)?
---@field private _now (fun(): number)?
---@field private _expectedVersionId string? edition required by a targeted import
---@field private _verified table<string, unknown>? one-shot validated buffer for the controller handoff
---@field private _registerGate (fun(): nil)? worker-only authorization before the binding write
---@field private _queued table<string, unknown>? live background session, when queued
---@field private _queueSeq integer background session counter guarding late packets
---@field private _queueCanceled boolean whether the queued session was retired
---@field private _queueRequest table<string, unknown>? restartable worker input for one retry
---@field private _pendingStart table<string, unknown>? deferred worker input while the process lease is occupied
---@field private _queueAttempts integer background starts for the live request
---@field private _commitSent boolean whether the live session authorized registration
local RomImporter = {}
RomImporter.__index = RomImporter

-- The importer's state vocabulary, shared by the UI/runner consumers so the
-- raw state strings have one owner.
RomImporter.STATES = {
  IDLE = "idle",
  READING = "reading",
  VERIFYING = "verifying",
  REGISTERING = "registering",
  COMPLETE = "complete",
  ERROR = "error",
}

local IMPORT_ERROR_CODES = {
  BUSY = "IMPORT_BUSY",
  NOT_NDS = "IMPORT_NOT_NDS",
}

-- Single process-local background reader lease across all importer instances.
-- At most one queued worker thread is physically live at a time. A retired
-- session keeps occupying the lease until its thread actually exits and its
-- outbox is drained; a newcomer waits as a pending starter without spawning
-- a second thread. Reserved and released only on the main thread.
local activeWorkerLease = nil

-- Nonblocking pop working for both LÖVE channels and table fakes.
---@param channel table<string, function>|userdata
---@return table<string, unknown>?
local function channelPop(channel)
  local ok, packet = pcall(function()
    return channel:pop()
  end)
  if not ok then
    return nil
  end
  return packet
end

---@param thread table<string, function>|userdata|nil
---@return boolean alive
local function leaseThreadAlive(thread)
  if thread == nil then
    return false
  end
  local ok, running = pcall(function()
    return thread:isRunning()
  end)
  return ok and running == true
end

-- Drain a retired worker's outbox without interpreting it, then release the
-- lease once the thread has exited and nothing remains queued. Stale terminal
-- packets (including large shared buffers) are discarded, never published.
local function serviceRetiredLease()
  local lease = activeWorkerLease
  if lease == nil or not lease.retired then
    return
  end
  local outbox = lease.outbox
  if outbox ~= nil then
    for _ = 1, 64 do
      if channelPop(outbox) == nil then
        break
      end
    end
  end
  if not leaseThreadAlive(lease.thread) then
    if outbox ~= nil then
      for _ = 1, 64 do
        if channelPop(outbox) == nil then
          break
        end
      end
      if channelPop(outbox) ~= nil then
        return
      end
    end
    activeWorkerLease = nil
  end
end

-- `versions` lets the importer verify readiness against an injected catalog in
-- tests; production callers (boot flow, batch CLI, test runner) use the
-- default GameVersion. Readiness is the strict persisted source binding
-- only: the registered file is never opened here, so a moved ROM never
-- blocks an installed cache and actual bytes load lazily on a real miss.
-- Whether the version already carries a persisted source registration.
-- Checked through the version cache only: the binding proves a prior
-- registration without opening the ROM, while a filename or launch route
-- alone never does. A failed or corrupt read counts as unregistered.
---@param cacheFs table<string, function> version cache holding the registration
---@param versionId string
---@return boolean
function RomImporter.isRegistered(cacheFs, versionId)
  local ok, binding = pcall(RomBinding.read, cacheFs, versionId)
  return ok and binding ~= nil
end

function RomImporter.isReady(versionId, cache, versions)
  local catalog = versions or GameVersion
  local info
  if type(catalog.info) == "function" then
    local ok, result = pcall(catalog.info, versionId)
    if ok and type(result) == "table" then
      info = result
    end
  elseif type(catalog.VERSIONS) == "table" then
    info = catalog.VERSIONS[versionId]
  end
  if not info then
    return false
  end
  cache = cache or CacheFs.forVersion(versionId)
  local binding = RomBinding.read(cache, versionId, versions)
  return binding ~= nil
end

-- Yield roughly every 8ms of work during validation and registration.
local YIELD_INTERVAL = 0.008

local function defaultNow()
  if love and love.timer then
    return love.timer.getTime()
  end
  return 0
end

-- opts: { onComplete=, versions=, cacheFactory=, now=, registerGate= }. All
-- optional; tests inject a synthetic version catalog, a FakeCache-backed
-- cacheFactory, and a static `now` (which disables yielding, so one
-- update() runs to completion). registerGate is worker-only: the
-- background worker authorizes its binding write through it, while the
-- direct path continues without a gate.
function RomImporter.new(opts)
  opts = opts or {}
  local expectedVersionId = opts.expectedVersionId
  if expectedVersionId ~= nil then
    assert(GameVersion.VERSIONS[expectedVersionId], "unknown expected game version")
  end
  if opts.registerGate ~= nil then
    assert(type(opts.registerGate) == "function", "registerGate must be a function")
  end
  return setmetatable({
    _onComplete = opts.onComplete,
    _versions = opts.versions or GameVersion,
    _cacheFactory = opts.cacheFactory or function(id)
      return CacheFs.forVersion(id)
    end,
    _now = opts.now or defaultNow,
    _expectedVersionId = expectedVersionId,
    _registerGate = opts.registerGate,
    _queueSeq = 0,
    _queueCanceled = false,
    _queueAttempts = 0,
    _commitSent = false,
    state = RomImporter.STATES.IDLE,
    progress = 0,
  }, RomImporter)
end

function RomImporter:status()
  return {
    state = self.state,
    versionId = self._versionId,
    displayName = self._displayName,
    sourceName = self._sourceName,
    progress = self.progress or 0,
    stage = self._stage,
    stageLabel = self._stageLabel,
    detail = self._detail,
    report = self._report,
    error = self._error,
    errorCode = self._errorCode,
  }
end

function RomImporter:isBusy()
  local s = RomImporter.STATES
  return self.state == s.READING or self.state == s.VERIFYING or self.state == s.REGISTERING
end

-- The importer owns its state-machine invariant: the start APIs accept every
-- state that is not an in-flight import (idle, complete, and error all
-- restart), and reject new requests while busy without touching the active
-- import.
function RomImporter:_requireNotBusy()
  if self:isBusy() then
    Errors.raise(IMPORT_ERROR_CODES.BUSY, "an import is already in progress", { state = self.state })
  end
end

function RomImporter:_fail(err)
  if self._source then
    self._source:release()
  end
  self._source, self._co, self._verified = nil, nil, nil
  self._error = err
  self._errorCode = Errors.is(err) and err.code or nil
  self.state = RomImporter.STATES.ERROR
  collectgarbage("collect")
end

function RomImporter:_complete(report)
  -- The string source is released, but the validated bytes stay available
  -- exactly once through takeVerifiedSource for the controller handoff.
  if self._source then
    self._source:release()
  end
  self._source, self._co = nil, nil
  self._report = report
  self.progress = 1
  self.state = RomImporter.STATES.COMPLETE
  collectgarbage("collect")
end

---@async
function RomImporter:_onProgress(p)
  self._stage = p.stage
  self._stageLabel = p.stageLabel
  self._detail = p.detail
  self.progress = p.overall
  local now = (self._now --[[@as fun(): number]])()
  if now - (self._lastYield or 0) >= YIELD_INTERVAL then
    self._lastYield = now
    coroutine.yield()
  end
end

-- Hand the validated buffer to the controller exactly once. The import
-- already converted the retained string into the one immutable shared
-- buffer before completion; the first take wraps it in a borrowed view,
-- and later takes (or takes before completion and takes after a failure)
-- answer nil. The bytes never enter the generated cache: only the binding
-- is persisted.
---@return table<string, unknown>? borrowed-source view over the shared buffer
function RomImporter:takeVerifiedSource()
  local verified = self._verified
  if type(verified) ~= "table" or type(verified.byteData) ~= "userdata" then
    return nil
  end
  self._verified = nil
  return RomSource.fromByteData(verified.byteData, verified.displayName)
end

-- Build the coroutine that validates then registers. Kept off the frame
-- thread so update() can spread the work; validation completes before any
-- cache write, and re-registering the same canonical ROM preserves every
-- receipt, asset, and save. A failed validation or registration leaves the
-- previous binding and all derived data untouched.
function RomImporter:_beginWork()
  local source = self._source
  self._co = coroutine.create(function()
    self.state = RomImporter.STATES.VERIFYING
    self._lastYield = (self._now --[[@as fun(): number]])()
    self:_onProgress({ stage = "verifying", stageLabel = "Verifying ROM", overall = 0.25 })
    local rom, err = NdsRom.open(source, self._versions --[[@as table]])
    if not rom then
      return self:_fail(err)
    end

    local info = rom:versionInfo()
    if self._expectedVersionId ~= nil and info.id ~= self._expectedVersionId then
      return self:_fail(
        Errors.new(
          "ROM_VERSION_MISMATCH",
          "selected ROM does not match the requested game version",
          { expectedVersionId = self._expectedVersionId, actualVersionId = info.id }
        )
      )
    end
    self._versionId = info.id
    self._displayName = info.displayName
    self._sourceName = source:displayName()
    local cache = (self._cacheFactory --[[@as fun(versionId: string): table]])(info.id)

    self.state = RomImporter.STATES.REGISTERING
    self:_onProgress({ stage = "registering", stageLabel = "Registering source", overall = 0.6 })
    local origin = source:origin()
    -- A dropped filename is only a candidate location: reopen that exact
    -- path (and member) and keep it solely when the same canonical bytes
    -- answer. Any failure degrades to an ephemeral registration; the
    -- dropped bytes themselves already validated above. The short-lived
    -- verification source is released before the session buffer exists.
    local candidate
    if type(source.reopenCandidatePath) == "function" then
      candidate = source:reopenCandidatePath()
    end
    if type(candidate) == "string" and candidate ~= "" then
      local reopenOptions
      if origin.kind == "zip" and type(origin.zipEntry) == "string" then
        reopenOptions = { zipEntry = origin.zipEntry }
      end
      local ok, durable = pcall(function()
        local reopened = RomSource.fromPath(candidate, reopenOptions)
        if not reopened then
          return false
        end
        local check = NdsRom.open(reopened, self._versions --[[@as table]])
        local same = check ~= nil
          and reopened:origin().kind == origin.kind
          and check:versionInfo().id == info.id
          and check:versionInfo().sha1 == info.sha1
        if check then
          check:release()
        else
          reopened:release()
        end
        return same
      end)
      if ok and durable then
        origin.path = candidate
      end
    end
    -- Worker-only authorization seam directly before the binding write.
    -- The direct path registers no gate, so its behavior is unchanged; the
    -- background worker announces its validated version here and waits for
    -- the game thread's explicit commit, and a cancel raises out of the
    -- validation coroutine so nothing is recorded.
    local gate = self._registerGate
    if gate ~= nil then
      gate()
    end
    local recorded, recordErr = RomBinding.record(cache, rom, {
      kind = origin.kind,
      path = origin.path,
      displayName = origin.displayName,
      zipEntry = origin.zipEntry,
    }, self._versions)
    if not recorded then
      return self:_fail(recordErr)
    end
    self:_onProgress({ stage = "registering", stageLabel = "Registering source", overall = 0.9 })
    local bytes, readErr = source:read(0, source:size())
    if bytes == nil then
      return self:_fail(readErr)
    end
    local byteData = love.data.newByteData(bytes)
    bytes = nil
    -- The validated cartridge wrapper is discarded here; the single
    -- terminal release below owns the string exactly once.
    self._verified = { byteData = byteData, displayName = origin.displayName }
    return self:_complete({
      sha1 = info.sha1,
      kind = origin.kind,
      path = origin.path,
      displayName = origin.displayName,
      zipEntry = origin.zipEntry,
    })
  end)
end

-- Start from an already-opened RomSource (used by tests and the start* helpers).
function RomImporter:startSource(source)
  self:_requireNotBusy()
  assert(source, "startSource requires a RomSource")
  self._source = source
  self._sourceName = source:displayName()
  self._verified = nil
  self._versionId, self._displayName = nil, nil
  self._report, self._error, self._errorCode = nil, nil, nil
  self._stage, self._stageLabel, self._detail = nil, nil, nil
  self._completeFired = false
  self.progress = 0
  self.state = RomImporter.STATES.READING
  self:_beginWork()
end

function RomImporter:startPath(path)
  self:_requireNotBusy()
  local source, err = RomSource.fromPath(path)
  if not source then
    return self:_fail(err)
  end
  return self:startSource(source)
end

function RomImporter:startDroppedFile(droppedFile)
  self:_requireNotBusy()
  local source, err = RomSource.fromDroppedFile(droppedFile)
  if not source then
    return self:_fail(err)
  end
  return self:startSource(source)
end

-- Drop handler with a friendly extension guard. Accepts a
-- raw .nds or a .zip containing one.
function RomImporter:filedropped(droppedFile)
  self:_requireNotBusy()
  local name = droppedFile:getFilename() or ""
  if not name:lower():match("%.nds$") and not name:lower():match("%.zip$") then
    return self:_fail(
      Errors.new(IMPORT_ERROR_CODES.NOT_NDS, "dropped file is not a .nds or .zip ROM: " .. name, { name = name })
    )
  end
  self:startDroppedFile(droppedFile)
end

-- Copy only channel-safe scalars so the version catalog snapshot crosses
-- into the background worker without carrying live objects.
---@param value unknown
---@param depth integer
---@return unknown? plain copy, or nil when the value cannot travel
local function plainValue(value, depth)
  if depth <= 0 then
    return nil
  end
  local kind = type(value)
  if kind == "string" or kind == "number" or kind == "boolean" then
    return value
  end
  if kind ~= "table" then
    return nil
  end
  local out = {}
  for key, item in pairs(value) do
    if type(key) == "string" or type(key) == "number" then
      local part = plainValue(item, depth - 1)
      if part ~= nil then
        out[key] = part
      end
    end
  end
  return out
end

-- Snapshot the version catalog as plain record data for the background
-- worker. GameVersion-shaped catalogs expose their VERSIONS table;
-- function catalogs are probed over the known version identities, which
-- also covers injected test catalogs answering the same lookup.
---@param versions table<string, unknown>
---@return table<integer, table<string, unknown>> plain version records
local function snapshotCatalog(versions)
  local entries, seen = {}, {}
  local function add(info)
    if type(info) == "table" and type(info.id) == "string" and not seen[info.id] then
      seen[info.id] = true
      local copied = plainValue(info, 4)
      if type(copied) == "table" then
        entries[#entries + 1] = copied
      end
    end
  end
  if type(versions) == "table" then
    local catalog = versions --[[@as table<string, unknown>]]
    if type(catalog.VERSIONS) == "table" then
      for _, info in
        pairs(catalog.VERSIONS --[[@as table<string, unknown>]])
      do
        add(info)
      end
    end
    if type(catalog.info) == "function" then
      local order = GameVersion.ORDER
      if type(catalog.ORDER) == "table" then
        order = catalog.ORDER --[[@as string[] ]]
      end
      local lookup = catalog.info --[[@as fun(string): unknown]]
      for _, id in ipairs(order) do
        local ok, info = pcall(lookup, id)
        if ok then
          add(info)
        end
      end
    end
  end
  return entries
end

---@param fraction unknown
---@return number clamped determinate fraction
local function clampFraction(fraction)
  if type(fraction) ~= "number" or fraction ~= fraction then
    return 0
  end
  if fraction < 0 then
    return 0
  end
  if fraction > 1 then
    return 1
  end
  return fraction
end

-- Start one background session for an already-built worker request. The
-- game thread performs no source read, hash, or registration here: the
-- worker owns the authoritative sequence and answers over its channels.
---@param request table<string, unknown> worker input (kind/path/file/bytes/name)
---@param requestId unknown? caller correlation, defaults to the next session id
---@param attempts integer? background starts so far for this request
---@return nil
function RomImporter:_startQueued(request, requestId, attempts)
  self._source, self._co, self._verified = nil, nil, nil
  self._versionId, self._displayName, self._sourceName = nil, nil, nil
  self._report, self._error, self._errorCode = nil, nil, nil
  self._stage, self._stageLabel, self._detail = nil, nil, nil
  self._completeFired = false
  self._queueCanceled = false
  self._commitSent = false
  self._queueAttempts = attempts or 1
  self._queueRequest = {
    kind = request.kind,
    path = request.path,
    file = request.file,
    bytes = request.bytes,
    name = request.name,
  }
  self.progress = 0
  self._queueSeq = (self._queueSeq or 0) + 1
  local id = requestId == nil and self._queueSeq or requestId
  serviceRetiredLease()
  if activeWorkerLease ~= nil then
    self._queued = nil
    self._pendingStart = {
      kind = request.kind,
      path = request.path,
      file = request.file,
      bytes = request.bytes,
      name = request.name,
      id = id,
      attempts = self._queueAttempts,
    }
    self._stage = "waiting"
    self._stageLabel = "Waiting for previous import"
    self._detail = nil
    self.state = RomImporter.STATES.READING
    return
  end
  local host = love ~= nil and love.thread or nil
  if type(host) ~= "table" or type(host.newChannel) ~= "function" or type(host.newThread) ~= "function" then
    return self:_fail(Errors.new("IMPORT_WORKER_UNAVAILABLE", "background import needs love.thread", {}))
  end
  local RomImportWorker = require("romdump.src.source.RomImportWorker")
  local inbox, outbox = host.newChannel(), host.newChannel()
  if inbox == nil or outbox == nil then
    return self:_fail(Errors.new("IMPORT_WORKER_UNAVAILABLE", "background import has no channels", {}))
  end
  request.id = id
  request.catalog = snapshotCatalog(self._versions --[[@as table<string, unknown>]])
  request.expectedVersionId = self._expectedVersionId
  if not pcall(inbox.push, inbox, request) then
    return self:_fail(Errors.new("IMPORT_WORKER_UNAVAILABLE", "background import could not take its request", {}))
  end
  local threadOk, threadOrErr = pcall(host.newThread, RomImportWorker.bootstrap())
  if not threadOk or threadOrErr == nil then
    return self:_fail(Errors.new("IMPORT_WORKER_UNAVAILABLE", "background import thread failed to start", {}))
  end
  local thread = threadOrErr --[[@as table<string, function>]]
  if not pcall(thread.start, thread, package.path, inbox, outbox) then
    return self:_fail(Errors.new("IMPORT_WORKER_UNAVAILABLE", "background import thread failed to start", {}))
  end
  activeWorkerLease = { thread = thread, inbox = inbox, outbox = outbox, id = id, retired = false }
  self._queued = { id = id, thread = thread, inbox = inbox, outbox = outbox }
  self._pendingStart = nil
  self.state = RomImporter.STATES.READING
end

-- Queue a path import for background validation. Unlike startPath, no source
-- is opened on the calling thread; progress and the terminal result arrive
-- through update(). requestId optionally correlates the session.
---@param path string picked .nds/.zip path
---@param requestId unknown? caller correlation
---@return nil
function RomImporter:queuePath(path, requestId)
  self:_requireNotBusy()
  assert(type(path) == "string" and path ~= "", "queuePath requires a ROM path")
  return self:_startQueued({ kind = "path", path = path }, requestId)
end

---@param name unknown raw dropped file label
---@return string? sanitized basename for the queued memory handoff
local function queuedDropName(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local base = (name:gsub("\\", "/"):match("([^/]+)$")) or name
  local clean = base:gsub("[%c]", "?")
  if clean == "" then
    return nil
  end
  return clean
end

-- Queue a dropped file for background validation. An invalid extension
-- fails synchronously without starting a worker. Host file handles travel
-- by reference so large reads stay in the worker; drops whose bytes are
-- already resident travel by value after the caller hands them over.
---@param droppedFile table<string, unknown>|userdata dropped file
---@param requestId unknown? caller correlation
---@return nil
function RomImporter:queueDroppedFile(droppedFile, requestId)
  self:_requireNotBusy()
  assert(droppedFile ~= nil, "queueDroppedFile requires a dropped file")
  local name = droppedFile:getFilename() or ""
  if not name:lower():match("%.nds$") and not name:lower():match("%.zip$") then
    return self:_fail(
      Errors.new(IMPORT_ERROR_CODES.NOT_NDS, "dropped file is not a .nds or .zip ROM: " .. name, { name = name })
    )
  end
  if type(droppedFile) == "userdata" then
    return self:_startQueued({ kind = "drop", file = droppedFile }, requestId)
  end
  local openOk, opened = pcall(droppedFile.open, droppedFile, "r")
  if not openOk or not opened then
    return self:_fail(Errors.new("ROM_OPEN_FAILED", tostring(opened), { name = name }))
  end
  local readOk, data = pcall(droppedFile.read, droppedFile)
  pcall(droppedFile.close, droppedFile)
  if not readOk or data == nil then
    return self:_fail(Errors.new("ROM_READ_FAILED", "could not read dropped file", { name = name }))
  end
  return self:_startQueued({ kind = "dropBytes", bytes = data, name = queuedDropName(name) or name }, requestId)
end

-- Retire the queued background session without blocking: the worker is told
-- to abandon its registration gate, late packets are invalidated, and the
-- session returns to idle. The physical lease is retained until the retired
-- thread actually exits and its outbox is drained. A direct (non-queued)
-- import is untouched.
function RomImporter:cancelQueued()
  local queued = self._queued
  local pending = self._pendingStart
  if queued == nil and pending == nil then
    return
  end
  self._queueSeq = (self._queueSeq or 0) + 1
  self._queueCanceled = true
  if pending ~= nil then
    self._pendingStart = nil
  end
  if queued ~= nil then
    self._queued = nil
    if activeWorkerLease ~= nil and activeWorkerLease.id == queued.id then
      activeWorkerLease.retired = true
    elseif activeWorkerLease == nil then
      activeWorkerLease = {
        thread = queued.thread,
        inbox = queued.inbox,
        outbox = queued.outbox,
        id = queued.id,
        retired = true,
      }
    end
    local inbox = queued.inbox --[[@as table<string, function>]]
    if type(inbox) == "table" or type(inbox) == "userdata" then
      pcall(inbox.push, inbox, { id = queued.id, op = "cancel" })
    end
  end
  self._verified = nil
  if self.state ~= RomImporter.STATES.COMPLETE and self.state ~= RomImporter.STATES.ERROR then
    self.state = RomImporter.STATES.IDLE
  end
  self.progress = 0
  self._stage, self._stageLabel, self._detail = nil, nil, nil
end

-- Mirror one worker status packet onto the visible import state so the
-- receipt card animates while validation runs elsewhere.
---@param packet table<string, unknown>
function RomImporter:_applyWorkerStatus(packet)
  local states = RomImporter.STATES
  if packet.state == states.READING or packet.state == states.VERIFYING or packet.state == states.REGISTERING then
    self.state = packet.state --[[@as string]]
  end
  self.progress = clampFraction(packet.progress)
  if packet.stage == nil or type(packet.stage) == "string" then
    self._stage = packet.stage
  end
  if packet.stageLabel == nil or type(packet.stageLabel) == "string" then
    self._stageLabel = packet.stageLabel
  end
  if packet.detail == nil or type(packet.detail) == "string" then
    self._detail = packet.detail
  end
end

-- Sending commit is the registration linearization point: it is answered
-- only for the live session, so a retired session can never authorize a
-- binding it no longer owns.
---@param queued table<string, unknown> live background session
---@return nil
function RomImporter:_answerValidationGate(queued)
  local inbox = queued.inbox --[[@as table<string, function>]]
  pcall(inbox.push, inbox, { id = queued.id, op = "commit" })
  self._commitSent = true
end

-- Accept one terminal worker result for the live session: publish the
-- worker-decided binding through the configured cache with the same
-- atomicity as a direct registration, then complete with the same
-- one-shot handoff. No revalidation happens on this thread.
---@param packet table<string, unknown>
---@return nil
function RomImporter:_acceptWorkerResult(packet)
  local sessionId = packet.id
  self._queued = nil
  self._pendingStart = nil
  if activeWorkerLease ~= nil and activeWorkerLease.id == sessionId then
    activeWorkerLease.retired = true
  end
  local cache = (self._cacheFactory --[[@as fun(versionId: string): table]])(packet.versionId)
  local published, publishErr = pcall(function()
    cache:writeLua(RomBinding.STAGE_PATH, packet.binding)
    cache:replace(RomBinding.STAGE_PATH, RomBinding.PATH)
  end)
  if not published then
    if Errors.is(publishErr) then
      return self:_fail(publishErr)
    end
    return self:_fail(publishErr)
  end
  self._versionId = packet.versionId
  self._displayName = packet.displayName
  self._sourceName = packet.sourceName
  self._verified = { byteData = packet.byteData, displayName = packet.displayName or packet.sourceName }
  self:_complete(packet.report --[[@as table<string, unknown>]])
end

---@param packet table<string, unknown>
---@return nil
function RomImporter:_failWorker(packet)
  local queued = self._queued
  self._queued = nil
  self._pendingStart = nil
  if queued ~= nil and activeWorkerLease ~= nil and activeWorkerLease.id == queued.id then
    activeWorkerLease.retired = true
  end
  self._queueRequest = nil
  self._verified = nil
  self:_fail(
    Errors.new(
      type(packet.errorCode) == "string" and packet.errorCode or "ROM_IMPORT_FAILED",
      type(packet.message) == "string" and packet.message or "background import failed",
      type(packet.context) == "table" and packet.context or {}
    )
  )
end

-- Restart a session whose worker produced no validation outcome.
-- Bounded to one retry: a repeated infrastructure failure still surfaces,
-- and validation failures never retry. The restart is safe at any point
-- before completion: the worker records only into its own staging, which
-- dies with it, while the durable publication happens on this thread for
-- the current session id alone. The retired session is canceled first, so
-- at most one worker stays current and its late packets no longer match.
---@param packet table<string, unknown> terminal infrastructure failure
---@return nil
function RomImporter:_failOrRetryWorker(packet)
  local code = packet.errorCode
  local infrastructure = code == "IMPORT_WORKER_LOST" or code == "ROM_IMPORT_WORKER_FAILED"
  local request = self._queueRequest
  local attempts = self._queueAttempts or 1
  if infrastructure and attempts < 2 and type(request) == "table" then
    self:cancelQueued()
    local retry = {
      kind = request.kind,
      path = request.path,
      file = request.file,
      bytes = request.bytes,
      name = request.name,
    }
    return self:_startQueued(retry, nil, attempts + 1)
  end
  return self:_failWorker(packet)
end

-- Drain worker packets without blocking. Only packets for the live session
-- id are honored; late packets from retired sessions are discarded, and a
-- worker that died without a terminal packet surfaces an explicit error.
---@param queued table<string, unknown> live background session
---@return nil
function RomImporter:_pollQueued(queued)
  local outbox = queued.outbox --[[@as table<string, function>]]
  for _ = 1, 64 do
    local packet = channelPop(outbox)
    if packet == nil then
      break
    end
    if type(packet) == "table" and packet.id == queued.id then
      if packet.kind == "status" then
        self:_applyWorkerStatus(packet)
      elseif packet.kind == "validated" then
        self:_answerValidationGate(queued)
      elseif packet.kind == "complete" then
        return self:_acceptWorkerResult(packet)
      elseif packet.kind == "error" then
        return self:_failOrRetryWorker(packet)
      end
    end
  end
  if self._queued ~= nil then
    local thread = queued.thread --[[@as table<string, function>]]
    local ok, running = pcall(function()
      return thread:isRunning()
    end)
    if ok and running == false then
      for _ = 1, 64 do
        local packet = channelPop(outbox)
        if packet == nil then
          break
        end
        if type(packet) == "table" and packet.id == queued.id then
          if packet.kind == "status" then
            self:_applyWorkerStatus(packet)
          elseif packet.kind == "validated" then
            self:_answerValidationGate(queued)
          elseif packet.kind == "complete" then
            return self:_acceptWorkerResult(packet)
          elseif packet.kind == "error" then
            return self:_failOrRetryWorker(packet)
          end
        end
      end
    end
    if self._queued ~= nil then
      local okStill, runningStill = pcall(function()
        return thread:isRunning()
      end)
      if okStill and runningStill == false then
        local _, threadError = pcall(thread.getError, thread)
        local context = {}
        if type(threadError) == "string" and threadError ~= "" then
          context.threadError = threadError
        end
        self:_failOrRetryWorker({
          errorCode = "IMPORT_WORKER_LOST",
          message = "background import ended without a result",
          context = context,
        })
      end
    end
  end
end

-- Resume the import coroutine one slice. Safe to call in any state. Fires
-- onComplete exactly once, outside the coroutine, on reaching "complete".
-- A queued session instead drains its worker packets here, still
-- nonblocking; the terminal packet completes with the same one-shot
-- semantics as the direct path.
function RomImporter:update()
  local co = self._co
  if co and coroutine.status(co) ~= "dead" then
    local ok, err = coroutine.resume(co)
    if not ok and self.state ~= RomImporter.STATES.ERROR then
      self:_fail(err)
    end
  end
  serviceRetiredLease()
  local queued = self._queued
  if queued ~= nil then
    self:_pollQueued(queued)
  end
  local pending = self._pendingStart
  if pending ~= nil and activeWorkerLease == nil and self._queued == nil then
    self._pendingStart = nil
    self:_startQueued({
      kind = pending.kind,
      path = pending.path,
      file = pending.file,
      bytes = pending.bytes,
      name = pending.name,
    }, pending.id, pending.attempts)
  end
  if self.state == RomImporter.STATES.COMPLETE and not self._completeFired then
    self._completeFired = true
    if self._onComplete then
      self._onComplete(self._versionId, self._report)
    end
  end
end

return RomImporter
